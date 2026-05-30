-- Admin reset for the one-time Free/Regular active venue selection.
-- This only clears the selection lock timestamp; it does not modify plans or venues.

CREATE OR REPLACE FUNCTION public.admin_reopen_free_active_venue_selection(
  p_business_id uuid,
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
    RAISE EXCEPTION 'missing_reopen_reason' USING ERRCODE = '22023';
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
    free_active_venues_selected_at = NULL,
    entitlement_updated_at = now()
  WHERE id = p_business_id;

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
    'reopen_free_active_venue_selection',
    'business',
    p_business_id::text,
    v_before,
    v_after,
    v_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'businessId', p_business_id,
    'freeActiveVenuesSelectedAt', NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reopen_free_active_venue_selection(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reopen_free_active_venue_selection(uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.admin_reopen_free_active_venue_selection(uuid, text, text) IS
  'Admin-only reset of businesses.free_active_venues_selected_at so a Regular business can choose active venues again. Does not update venue rows or plan fields.';

NOTIFY pgrst, 'reload schema';
