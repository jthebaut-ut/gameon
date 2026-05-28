-- Business owners can withdraw pending/open venue claims before admin review.
-- Keeps the audit row and marks it cancelled so duplicate/preflight and counts
-- no longer treat it as active.

CREATE OR REPLACE FUNCTION public.gameon_venue_claim_is_open_pending(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NOT (
    lower(trim(COALESCE(p_status, ''))) = 'approved'
    OR lower(trim(COALESCE(p_status, ''))) = 'released'
    OR lower(trim(COALESCE(p_status, ''))) = 'business_deleted'
    OR lower(trim(COALESCE(p_status, ''))) = 'cancelled'
    OR lower(trim(COALESCE(p_status, ''))) = 'withdrawn'
    OR lower(trim(COALESCE(p_status, ''))) LIKE '%reject%'
  );
$$;

CREATE OR REPLACE FUNCTION public.cancel_business_venue_claim(
  p_claim_id uuid,
  p_business_id uuid
)
RETURNS TABLE (
  claim_id uuid,
  business_id uuid,
  previous_status text,
  new_status text,
  cancelled_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_claim public.venue_claims%ROWTYPE;
  v_business public.businesses%ROWTYPE;
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_new_status text := 'cancelled';
  v_cancelled_at timestamptz := now();
  v_has_updated_at boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  IF v_email = '' THEN
    SELECT lower(btrim(coalesce(u.email, '')))
      INTO v_email
    FROM auth.users u
    WHERE u.id = auth.uid();
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses AS b
  WHERE b.id = p_business_id
    AND lower(btrim(coalesce(b.admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized to cancel venue claims for this business.' USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_claim
  FROM public.venue_claims AS vc
  WHERE vc.id = p_claim_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Venue claim not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.gameon_venue_claim_is_open_pending(v_claim.approval_status) THEN
    RAISE EXCEPTION 'Only pending venue claims can be cancelled.' USING ERRCODE = 'P0001';
  END IF;

  IF v_claim.business_id IS NOT NULL AND v_claim.business_id IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Not authorized to cancel this venue claim.' USING ERRCODE = '42501';
  END IF;

  IF v_claim.business_id IS NULL
     AND lower(btrim(coalesce(v_claim.owner_email, ''))) IS DISTINCT FROM v_email THEN
    RAISE EXCEPTION 'Not authorized to cancel this venue claim.' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'venue_claims'
      AND column_name = 'updated_at'
  )
  INTO v_has_updated_at;

  IF v_has_updated_at THEN
    EXECUTE
      'UPDATE public.venue_claims SET approval_status = $1, updated_at = $2 WHERE id = $3'
      USING v_new_status, v_cancelled_at, p_claim_id;
  ELSE
    UPDATE public.venue_claims
    SET approval_status = v_new_status
    WHERE id = p_claim_id;
  END IF;

  RETURN QUERY
  SELECT
    p_claim_id AS claim_id,
    p_business_id AS business_id,
    coalesce(v_claim.approval_status, '') AS previous_status,
    v_new_status AS new_status,
    v_cancelled_at AS cancelled_at;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_business_venue_claim(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_business_venue_claim(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.cancel_business_venue_claim(uuid, uuid) IS
  'Business owner RPC to soft-cancel pending/open venue_claims before admin review. Keeps the row for admin history.';

NOTIFY pgrst, 'reload schema';
