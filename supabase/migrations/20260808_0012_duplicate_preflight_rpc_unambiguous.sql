-- Remove overloaded duplicate-check RPC ambiguity for PostgREST.
-- The iOS client now sends p_exclude_claim_id explicitly as null when unused.

DROP FUNCTION IF EXISTS public.check_venue_claim_duplicate(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text
);

CREATE OR REPLACE FUNCTION public.check_venue_claim_duplicate(
  p_business_id uuid,
  p_owner_email text,
  p_venue_name text,
  p_venue_address text,
  p_venue_city text,
  p_venue_state text,
  p_venue_zip text,
  p_exclude_claim_id uuid DEFAULT NULL
)
RETURNS TABLE(code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  k text;
  same_biz_venue boolean;
  same_biz_approved_claim boolean;
  same_biz_pending_claim boolean;
  other_active_venue boolean;
  other_open_claim boolean;
BEGIN
  k := public.gameon_venue_identity_key(
    p_venue_name,
    p_venue_address,
    p_venue_city,
    p_venue_state,
    p_venue_zip
  );

  SELECT EXISTS (
    SELECT 1
    FROM public.venues AS v
    WHERE v.venue_identity_key = k
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        (p_business_id IS NOT NULL AND v.business_id IS NOT DISTINCT FROM p_business_id)
        OR (
          p_business_id IS NULL
          AND v.business_id IS NULL
          AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(coalesce(p_owner_email, '')))
        )
      )
  )
  INTO same_biz_venue;

  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims AS c
    WHERE c.venue_identity_key = k
      AND (p_exclude_claim_id IS NULL OR c.id IS DISTINCT FROM p_exclude_claim_id)
      AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
      AND c.business_id IS NOT DISTINCT FROM p_business_id
      AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(coalesce(p_owner_email, '')))
  )
  INTO same_biz_approved_claim;

  IF same_biz_venue OR same_biz_approved_claim THEN
    RETURN QUERY SELECT 'duplicate_venue_same_business'::text;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims AS c
    WHERE c.venue_identity_key = k
      AND (p_exclude_claim_id IS NULL OR c.id IS DISTINCT FROM p_exclude_claim_id)
      AND public.gameon_venue_claim_is_open_pending(c.approval_status)
      AND c.business_id IS NOT DISTINCT FROM p_business_id
      AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(coalesce(p_owner_email, '')))
  )
  INTO same_biz_pending_claim;

  IF same_biz_pending_claim THEN
    RETURN QUERY SELECT 'duplicate_claim_pending'::text;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.venues AS v
    WHERE v.venue_identity_key = k
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND NOT (
        (p_business_id IS NOT NULL AND v.business_id IS NOT DISTINCT FROM p_business_id)
        OR (
          p_business_id IS NULL
          AND v.business_id IS NULL
          AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(coalesce(p_owner_email, '')))
        )
      )
  )
  INTO other_active_venue;

  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims AS c
    WHERE c.venue_identity_key = k
      AND (p_exclude_claim_id IS NULL OR c.id IS DISTINCT FROM p_exclude_claim_id)
      AND (
        public.gameon_venue_claim_is_open_pending(c.approval_status)
        OR lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
      )
      AND NOT (
        c.business_id IS NOT DISTINCT FROM p_business_id
        AND lower(btrim(coalesce(c.owner_email, ''))) = lower(btrim(coalesce(p_owner_email, '')))
      )
  )
  INTO other_open_claim;

  IF other_active_venue OR other_open_claim THEN
    RETURN QUERY SELECT 'duplicate_venue_other_business'::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'ok'::text;
END;
$$;

REVOKE ALL ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO service_role;

COMMENT ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) IS
  'Duplicate preflight for venue claims. Uses a single explicit 8-parameter PostgREST signature; pass p_exclude_claim_id as null when unused.';

NOTIFY pgrst, 'reload schema';
