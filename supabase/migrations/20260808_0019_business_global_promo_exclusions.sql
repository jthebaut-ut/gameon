-- Per-business exclusion from the global Free User Promo.
-- This does not change stored plan fields, promotion dates, hosted-game limits, or venue limits.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS exclude_from_global_business_pro_promo boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS global_business_pro_promo_excluded_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS global_business_pro_promo_excluded_by text NULL,
  ADD COLUMN IF NOT EXISTS global_business_pro_promo_exclusion_reason text NULL;

COMMENT ON COLUMN public.businesses.exclude_from_global_business_pro_promo IS
  'Admin-only flag that prevents the global Free User Promo from granting effective Pro to this business.';
COMMENT ON COLUMN public.businesses.global_business_pro_promo_excluded_at IS
  'Timestamp when the business was most recently excluded from the global Free User Promo.';
COMMENT ON COLUMN public.businesses.global_business_pro_promo_excluded_by IS
  'Admin email that most recently excluded this business from the global Free User Promo.';
COMMENT ON COLUMN public.businesses.global_business_pro_promo_exclusion_reason IS
  'Admin reason for the current global Free User Promo exclusion.';

CREATE INDEX IF NOT EXISTS idx_businesses_global_pro_promo_exclusion
  ON public.businesses (exclude_from_global_business_pro_promo)
  WHERE exclude_from_global_business_pro_promo = true;

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
    AND b.admin_archived_at IS NULL
    AND COALESCE(b.exclude_from_global_business_pro_promo, false) = false;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_business_global_pro_promo_exclusion(
  p_business_id uuid,
  p_excluded boolean,
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
  v_before jsonb;
  v_after jsonb;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'missing_business_id' USING ERRCODE = '22023';
  END IF;

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'missing_exclusion_reason' USING ERRCODE = '22023';
  END IF;

  SELECT to_jsonb(b)
    INTO v_before
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.businesses
  SET
    exclude_from_global_business_pro_promo = COALESCE(p_excluded, false),
    global_business_pro_promo_excluded_at = CASE WHEN COALESCE(p_excluded, false) THEN now() ELSE NULL END,
    global_business_pro_promo_excluded_by = CASE
      WHEN COALESCE(p_excluded, false) THEN COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown')
      ELSE NULL
    END,
    global_business_pro_promo_exclusion_reason = CASE WHEN COALESCE(p_excluded, false) THEN v_reason ELSE NULL END
  WHERE id = p_business_id;

  PERFORM public.enforce_business_plan_venue_locks(p_business_id);

  SELECT to_jsonb(b)
    INTO v_after
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs(
    admin_email,
    action,
    target_type,
    target_id,
    before_data,
    after_data,
    reason
  )
  VALUES (
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    CASE
      WHEN COALESCE(p_excluded, false) THEN 'exclude_business_from_free_user_promo'
      ELSE 'include_business_in_free_user_promo'
    END,
    'business',
    p_business_id::text,
    v_before,
    v_after,
    v_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'businessId', p_business_id,
    'excluded', COALESCE(p_excluded, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.global_business_pro_promotion_applies_to(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_global_pro_promo_exclusion(uuid, boolean, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_set_business_global_pro_promo_exclusion(uuid, boolean, text, text) TO service_role;

COMMENT ON FUNCTION public.global_business_pro_promotion_applies_to(public.businesses) IS
  'Returns true when the global Free User Promo grants Pro to an active, non-excluded business.';
COMMENT ON FUNCTION public.admin_set_business_global_pro_promo_exclusion(uuid, boolean, text, text) IS
  'Admin-only toggle for excluding or re-including one business in the global Free User Promo.';

NOTIFY pgrst, 'reload schema';
