-- Secure one-time Free/Regular active venue selection.
-- Client code must not update venues.admin_status or businesses entitlement audit columns directly.

CREATE OR REPLACE FUNCTION public.save_free_active_business_venues(
  p_business_id uuid,
  p_active_venue_ids uuid[]
)
RETURNS TABLE (
  success boolean,
  active_count integer,
  locked_count integer
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
  v_venue_limit integer;
  v_selected_count integer;
  v_allowed_count integer;
  v_locked_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id
    AND lower(btrim(coalesce(admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;

  v_plan_type := lower(btrim(coalesce(v_business.plan_type, 'free')));
  v_plan_status := lower(btrim(coalesce(v_business.plan_status, 'active')));
  v_is_pro_active :=
    v_plan_status = 'active'
    AND (
      v_plan_type IN ('pro_promo', 'pro_paid', 'manual_pro')
      OR coalesce(v_business.unlimited_venues, false)
    )
    AND (v_business.pro_expires_at IS NULL OR v_business.pro_expires_at > now());

  IF v_is_pro_active THEN
    RAISE EXCEPTION 'business_is_pro' USING ERRCODE = 'P0001';
  END IF;

  v_venue_limit := GREATEST(0, coalesce(v_business.admin_active_venue_limit_override, v_business.venue_limit, 5));

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  SELECT count(*)::integer
    INTO v_selected_count
  FROM selected
  WHERE venue_id IS NOT NULL;

  IF v_selected_count = 0 THEN
    RAISE EXCEPTION 'no_active_venues_selected' USING ERRCODE = '22023';
  END IF;

  IF v_selected_count > v_venue_limit THEN
    RAISE EXCEPTION 'active_venue_limit_exceeded' USING ERRCODE = 'P0001';
  END IF;

  WITH managed_venues AS (
    SELECT DISTINCT v.id
    FROM public.venues v
    WHERE lower(btrim(coalesce(v.admin_status, 'active'))) IN ('active', 'plan_locked')
      AND (
        v.business_id = p_business_id
        OR (
          v.business_id IS NULL
          AND v_business.owner_email IS NOT NULL
          AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(v_business.owner_email))
        )
        OR EXISTS (
          SELECT 1
          FROM public.venue_claims c
          WHERE c.venue_id = v.id
            AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
            AND (
              c.business_id = p_business_id
              OR (
                v_business.owner_email IS NOT NULL
                AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(v_business.owner_email))
              )
            )
        )
      )
  ),
  selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  ),
  invalid_selected AS (
    SELECT s.venue_id
    FROM selected s
    LEFT JOIN managed_venues mv ON mv.id = s.venue_id
    WHERE s.venue_id IS NOT NULL
      AND mv.id IS NULL
  )
  SELECT count(*)::integer
    INTO v_allowed_count
  FROM invalid_selected;

  IF v_allowed_count > 0 THEN
    RAISE EXCEPTION 'selected_venue_not_owned_by_business' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  WITH managed_venues AS (
    SELECT DISTINCT v.id
    FROM public.venues v
    WHERE lower(btrim(coalesce(v.admin_status, 'active'))) IN ('active', 'plan_locked')
      AND (
        v.business_id = p_business_id
        OR (
          v.business_id IS NULL
          AND v_business.owner_email IS NOT NULL
          AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(v_business.owner_email))
        )
        OR EXISTS (
          SELECT 1
          FROM public.venue_claims c
          WHERE c.venue_id = v.id
            AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
            AND (
              c.business_id = p_business_id
              OR (
                v_business.owner_email IS NOT NULL
                AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(v_business.owner_email))
              )
            )
        )
      )
  ),
  selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  UPDATE public.venues v
  SET admin_status = CASE
    WHEN EXISTS (SELECT 1 FROM selected s WHERE s.venue_id = v.id) THEN 'active'
    ELSE 'plan_locked'
  END
  FROM managed_venues mv
  WHERE v.id = mv.id;

  UPDATE public.businesses
  SET
    free_active_venues_selected_at = now(),
    entitlement_updated_at = now()
  WHERE id = p_business_id;

  WITH managed_venues AS (
    SELECT DISTINCT v.id, lower(btrim(coalesce(v.admin_status, 'active'))) AS status
    FROM public.venues v
    WHERE (
      v.business_id = p_business_id
      OR (
        v.business_id IS NULL
        AND v_business.owner_email IS NOT NULL
        AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(v_business.owner_email))
      )
      OR EXISTS (
        SELECT 1
        FROM public.venue_claims c
        WHERE c.venue_id = v.id
          AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
          AND (
            c.business_id = p_business_id
            OR (
              v_business.owner_email IS NOT NULL
              AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(v_business.owner_email))
            )
          )
      )
    )
  )
  SELECT
    count(*) FILTER (WHERE status = 'active')::integer,
    count(*) FILTER (WHERE status = 'plan_locked')::integer
    INTO v_selected_count, v_locked_count
  FROM managed_venues;

  RETURN QUERY
  SELECT true, coalesce(v_selected_count, 0), coalesce(v_locked_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) TO authenticated;

COMMENT ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) IS
  'One-time Free/Regular active venue selection. Verifies business ownership and updates approved managed venues to active/plan_locked transactionally.';
