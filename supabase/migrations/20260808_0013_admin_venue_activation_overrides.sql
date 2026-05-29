-- Admin venue activation overrides for Free/Regular businesses.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS admin_active_venue_limit_override integer NULL;

COMMENT ON COLUMN public.businesses.admin_active_venue_limit_override IS
  'Admin-only Free/Regular active venue limit override. NULL means use businesses.venue_limit.';

ALTER TABLE public.venues
  DROP CONSTRAINT IF EXISTS venues_admin_status_check;

ALTER TABLE public.venues
  ADD CONSTRAINT venues_admin_status_check
  CHECK (admin_status IN ('active', 'plan_locked', 'archived'));

CREATE OR REPLACE FUNCTION public.admin_venue_override_effective_limit(
  p_is_pro boolean,
  p_venue_limit integer,
  p_override integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_is_pro THEN NULL::integer
    ELSE GREATEST(0, COALESCE(p_override, p_venue_limit, 5))
  END;
$$;

CREATE OR REPLACE FUNCTION public.admin_venue_override_is_pro(b public.businesses)
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

CREATE OR REPLACE FUNCTION public.admin_business_managed_venue_ids(p_business_id uuid)
RETURNS TABLE (venue_id uuid)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH target_business AS (
    SELECT *
    FROM public.businesses
    WHERE id = p_business_id
  )
  SELECT DISTINCT v.id
  FROM public.venues v
  CROSS JOIN target_business b
  WHERE lower(btrim(coalesce(v.admin_status, 'active'))) IN ('active', 'plan_locked')
    AND (
      v.business_id = b.id
      OR (
        v.business_id IS NULL
        AND b.owner_email IS NOT NULL
        AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(b.owner_email))
      )
      OR EXISTS (
        SELECT 1
        FROM public.venue_claims c
        WHERE c.venue_id = v.id
          AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
          AND (
            c.business_id = b.id
            OR (
              b.owner_email IS NOT NULL
              AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(b.owner_email))
            )
          )
      )
    );
$$;

CREATE OR REPLACE FUNCTION public.enforce_business_plan_venue_locks(p_business_id uuid)
RETURNS void
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
  v_effective_limit integer;
  v_active_venue_count integer := 0;
  v_row record;
BEGIN
  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_plan_type := COALESCE(NULLIF(btrim(v_business.plan_type), ''), 'free');
  v_plan_status := COALESCE(NULLIF(btrim(v_business.plan_status), ''), 'active');
  v_is_pro_active := public.admin_venue_override_is_pro(v_business);
  v_effective_limit := public.admin_venue_override_effective_limit(
    v_is_pro_active,
    v_business.venue_limit,
    v_business.admin_active_venue_limit_override
  );

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  SELECT count(*)::integer
    INTO v_active_venue_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

  IF v_is_pro_active THEN
    FOR v_row IN
      UPDATE public.venues v
      SET admin_status = 'active'
      WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
        AND lower(btrim(coalesce(v.admin_status, ''))) = 'plan_locked'
      RETURNING v.id
    LOOP
      RAISE NOTICE '[BusinessPlanLock] businessId=% venueId=% previousStatus=% newStatus=% activeVenueCount=% planType=% planStatus=% downgradeDetected=%',
        p_business_id, v_row.id, 'plan_locked', 'active', v_active_venue_count, v_plan_type, v_plan_status, false;
    END LOOP;
    RETURN;
  END IF;

  FOR v_row IN
    WITH ranked AS (
      SELECT
        v.id,
        coalesce(nullif(btrim(v.admin_status), ''), 'active') AS previous_status,
        row_number() OVER (ORDER BY v.created_at DESC NULLS LAST, v.id DESC) AS active_rank
      FROM public.venues v
      WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
        AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
    )
    UPDATE public.venues v
    SET admin_status = 'plan_locked'
    FROM ranked r
    WHERE v.id = r.id
      AND r.active_rank > COALESCE(v_effective_limit, 0)
    RETURNING v.id, r.previous_status
  LOOP
    RAISE NOTICE '[BusinessPlanLock] businessId=% venueId=% previousStatus=% newStatus=% activeVenueCount=% planType=% planStatus=% downgradeDetected=%',
      p_business_id, v_row.id, v_row.previous_status, 'plan_locked', v_active_venue_count, v_plan_type, v_plan_status, true;
  END LOOP;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_enforce_plan_venue_locks ON public.businesses;
CREATE TRIGGER trg_businesses_enforce_plan_venue_locks
AFTER INSERT OR UPDATE OF plan_type, plan_status, pro_expires_at, unlimited_venues, unlimited_hosting, venue_limit, monthly_host_limit, admin_active_venue_limit_override
ON public.businesses
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_business_plan_venue_locks();

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
VOLATILE
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
  v_effective_venue_limit := public.admin_venue_override_effective_limit(
    v_is_pro_active,
    v_business.venue_limit,
    v_business.admin_active_venue_limit_override
  );

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
    COALESCE(v_business.sponsored_enabled, true) AS sponsored_enabled,
    v_is_pro_active AS unlimited_venues,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.unlimited_hosting, false) ELSE false END AS unlimited_hosting,
    CASE WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.venue_limit, 999999)) ELSE COALESCE(v_effective_venue_limit, 5) END AS venue_limit,
    CASE WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.monthly_host_limit, 999999)) ELSE GREATEST(0, COALESCE(v_business.monthly_host_limit, 5)) END AS monthly_host_limit,
    COALESCE(v_venues_used, 0) AS venues_used,
    COALESCE(v_hosted_games_this_month, 0) AS hosted_games_this_month;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_business_venue_override_summaries(p_admin_email text)
RETURNS TABLE (
  business_id uuid,
  display_name text,
  owner_email text,
  plan_type text,
  plan_status text,
  computed_is_pro boolean,
  venue_limit integer,
  effective_venue_limit integer,
  admin_active_venue_limit_override integer,
  approved_count integer,
  active_count integer,
  locked_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH b AS (
    SELECT *
    FROM public.businesses
    WHERE lower(btrim(coalesce(admin_status, ''))) = 'active'
  ),
  counts AS (
    SELECT
      b.id AS business_id,
      count(DISTINCT v.id)::integer AS approved_count,
      count(DISTINCT v.id) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active')::integer AS active_count,
      count(DISTINCT v.id) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'plan_locked')::integer AS locked_count
    FROM b
    LEFT JOIN public.venues v ON v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(b.id))
    GROUP BY b.id
  )
  SELECT
    b.id,
    b.display_name,
    b.owner_email,
    COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') AS plan_type,
    COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') AS plan_status,
    public.admin_venue_override_is_pro(b) AS computed_is_pro,
    COALESCE(b.venue_limit, 5) AS venue_limit,
    public.admin_venue_override_effective_limit(public.admin_venue_override_is_pro(b), b.venue_limit, b.admin_active_venue_limit_override) AS effective_venue_limit,
    b.admin_active_venue_limit_override,
    COALESCE(c.approved_count, 0),
    COALESCE(c.active_count, 0),
    COALESCE(c.locked_count, 0)
  FROM b
  LEFT JOIN counts c ON c.business_id = b.id
  ORDER BY lower(coalesce(b.display_name, '')), b.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_business_venue_override_venues(
  p_business_id uuid,
  p_admin_email text
)
RETURNS TABLE (
  venue_id uuid,
  business_id uuid,
  venue_name text,
  city text,
  state text,
  admin_status text,
  created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    v.id,
    p_business_id,
    v.venue_name,
    v.city,
    v.state,
    coalesce(nullif(btrim(v.admin_status), ''), 'active') AS admin_status,
    v.created_at
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
  ORDER BY
    CASE WHEN lower(btrim(coalesce(v.admin_status, 'active'))) = 'active' THEN 0 ELSE 1 END,
    v.created_at DESC NULLS LAST,
    lower(coalesce(v.venue_name, ''));
$$;

CREATE OR REPLACE FUNCTION public.admin_set_business_active_venue_limit_override(
  p_business_id uuid,
  p_admin_email text,
  p_override integer
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
BEGIN
  IF p_override IS NULL OR p_override < 0 THEN
    RAISE EXCEPTION 'invalid_override_limit' USING ERRCODE = '22023';
  END IF;

  SELECT to_jsonb(b) INTO v_before
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.businesses
  SET
    admin_active_venue_limit_override = p_override,
    entitlement_updated_at = now()
  WHERE id = p_business_id;

  PERFORM public.enforce_business_plan_venue_locks(p_business_id);

  SELECT to_jsonb(b) INTO v_after
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs(admin_email, action, target_type, target_id, before_data, after_data, reason)
  VALUES (
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    'set_business_active_venue_limit_override',
    'business',
    p_business_id::text,
    v_before,
    v_after,
    'Admin active venue limit override set'
  );

  RETURN jsonb_build_object('ok', true, 'override', p_override);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_clear_business_active_venue_limit_override(
  p_business_id uuid,
  p_admin_email text
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
BEGIN
  SELECT to_jsonb(b) INTO v_before
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.businesses
  SET
    admin_active_venue_limit_override = NULL,
    entitlement_updated_at = now()
  WHERE id = p_business_id;

  PERFORM public.enforce_business_plan_venue_locks(p_business_id);

  SELECT to_jsonb(b) INTO v_after
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs(admin_email, action, target_type, target_id, before_data, after_data, reason)
  VALUES (
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    'clear_business_active_venue_limit_override',
    'business',
    p_business_id::text,
    v_before,
    v_after,
    'Admin active venue limit override cleared'
  );

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_business_venue_activation(
  p_business_id uuid,
  p_venue_id uuid,
  p_admin_email text,
  p_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_before jsonb;
  v_after jsonb;
  v_is_pro boolean;
  v_effective_limit integer;
  v_active_count integer;
  v_new_status text;
BEGIN
  SELECT * INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.admin_business_managed_venue_ids(p_business_id) mv
    WHERE mv.venue_id = p_venue_id
  ) THEN
    RAISE EXCEPTION 'venue_not_owned_by_business' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(v) INTO v_before
  FROM public.venues v
  WHERE v.id = p_venue_id;

  v_is_pro := public.admin_venue_override_is_pro(v_business);
  v_effective_limit := public.admin_venue_override_effective_limit(v_is_pro, v_business.venue_limit, v_business.admin_active_venue_limit_override);
  v_new_status := CASE WHEN p_active THEN 'active' ELSE 'plan_locked' END;

  IF p_active AND NOT v_is_pro THEN
    SELECT count(*)::integer INTO v_active_count
    FROM public.venues v
    WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
      AND v.id <> p_venue_id
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

    IF v_active_count >= COALESCE(v_effective_limit, 0) THEN
      RAISE EXCEPTION 'effective_venue_limit_reached' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  UPDATE public.venues
  SET admin_status = v_new_status
  WHERE id = p_venue_id;

  UPDATE public.businesses
  SET entitlement_updated_at = now()
  WHERE id = p_business_id;

  SELECT to_jsonb(v) INTO v_after
  FROM public.venues v
  WHERE v.id = p_venue_id;

  INSERT INTO public.admin_audit_logs(admin_email, action, target_type, target_id, before_data, after_data, reason)
  VALUES (
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    CASE WHEN p_active THEN 'activate_business_venue' ELSE 'deactivate_business_venue' END,
    'venue',
    p_venue_id::text,
    v_before,
    jsonb_build_object('venue', v_after, 'business_id', p_business_id),
    CASE WHEN p_active THEN 'Admin activated venue' ELSE 'Admin deactivated venue' END
  );

  RETURN jsonb_build_object('ok', true, 'newStatus', v_new_status);
END;
$$;

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
  v_is_pro_active boolean;
  v_venue_limit integer;
  v_selected_count integer;
  v_invalid_count integer;
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

  v_is_pro_active := public.admin_venue_override_is_pro(v_business);
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

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  ),
  invalid_selected AS (
    SELECT s.venue_id
    FROM selected s
    LEFT JOIN public.admin_business_managed_venue_ids(p_business_id) mv ON mv.venue_id = s.venue_id
    WHERE s.venue_id IS NOT NULL
      AND mv.venue_id IS NULL
  )
  SELECT count(*)::integer
    INTO v_invalid_count
  FROM invalid_selected;

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'selected_venue_not_owned_by_business' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  UPDATE public.venues v
  SET admin_status = CASE
    WHEN EXISTS (SELECT 1 FROM selected s WHERE s.venue_id = v.id) THEN 'active'
    ELSE 'plan_locked'
  END
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id));

  UPDATE public.businesses
  SET
    free_active_venues_selected_at = now(),
    entitlement_updated_at = now()
  WHERE id = p_business_id;

  SELECT
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active')::integer,
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'plan_locked')::integer
    INTO v_selected_count, v_locked_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id));

  RETURN QUERY
  SELECT true, coalesce(v_selected_count, 0), coalesce(v_locked_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_venue_override_effective_limit(boolean, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_venue_override_is_pro(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_managed_venue_ids(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_venue_override_summaries(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_venue_override_venues(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_business_venue_override_summaries(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_business_venue_override_venues(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
