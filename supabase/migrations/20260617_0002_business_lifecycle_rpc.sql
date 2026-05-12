-- Transactional business archive/restore lifecycle RPCs.
-- Supabase runs each function call in a single database transaction.

CREATE OR REPLACE FUNCTION public.archive_business_lifecycle(
  p_business_id uuid,
  p_admin_email text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before_business jsonb;
  v_after_business jsonb;
  v_venue_ids uuid[];
  v_venues_count integer := 0;
  v_venue_events_count integer := 0;
  v_timestamp timestamptz := now();
BEGIN
  SELECT to_jsonb(b)
    INTO v_before_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_before_business IS NULL THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(array_agg(v.id), ARRAY[]::uuid[])
    INTO v_venue_ids
  FROM public.venues v
  WHERE v.business_id = p_business_id;

  UPDATE public.businesses
  SET
    admin_status = 'archived',
    admin_archived_at = v_timestamp,
    admin_archived_by = p_admin_email,
    admin_archived_reason = NULLIF(BTRIM(COALESCE(p_reason, '')), '')
  WHERE id = p_business_id;

  SELECT to_jsonb(b)
    INTO v_after_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF COALESCE(array_length(v_venue_ids, 1), 0) > 0 THEN
    UPDATE public.venues
    SET
      admin_status = 'archived',
      admin_archived_at = v_timestamp,
      admin_archived_by = p_admin_email,
      admin_archived_reason = NULLIF(BTRIM(COALESCE(p_reason, '')), '')
    WHERE id = ANY(v_venue_ids);

    GET DIAGNOSTICS v_venues_count = ROW_COUNT;

    UPDATE public.venue_events
    SET
      admin_status = 'archived',
      admin_archived_at = v_timestamp,
      admin_archived_by = p_admin_email,
      admin_archived_reason = NULLIF(BTRIM(COALESCE(p_reason, '')), '')
    WHERE venue_id = ANY(v_venue_ids);

    GET DIAGNOSTICS v_venue_events_count = ROW_COUNT;
  END IF;

  INSERT INTO public.admin_audit_logs (
    admin_email,
    action,
    target_type,
    target_id,
    before_data,
    after_data,
    reason
  )
  VALUES (
    p_admin_email,
    'archive_business',
    'business',
    p_business_id::text,
    v_before_business,
    jsonb_build_object(
      'business', v_after_business,
      'affected_counts', jsonb_build_object(
        'venues', v_venues_count,
        'venueEvents', v_venue_events_count
      )
    ),
    NULLIF(BTRIM(COALESCE(p_reason, '')), '')
  );

  RETURN jsonb_build_object(
    'venues', v_venues_count,
    'venueEvents', v_venue_events_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_business_lifecycle(
  p_business_id uuid,
  p_admin_email text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before_business jsonb;
  v_after_business jsonb;
BEGIN
  SELECT to_jsonb(b)
    INTO v_before_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_before_business IS NULL THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.businesses
  SET
    admin_status = 'active',
    admin_archived_at = NULL,
    admin_archived_by = NULL,
    admin_archived_reason = NULL
  WHERE id = p_business_id;

  SELECT to_jsonb(b)
    INTO v_after_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs (
    admin_email,
    action,
    target_type,
    target_id,
    before_data,
    after_data,
    reason
  )
  VALUES (
    p_admin_email,
    'restore_business',
    'business',
    p_business_id::text,
    v_before_business,
    jsonb_build_object(
      'business', v_after_business,
      'affected_counts', jsonb_build_object(
        'venues', 0,
        'venueEvents', 0
      )
    ),
    NULLIF(BTRIM(COALESCE(p_reason, '')), '')
  );

  RETURN jsonb_build_object(
    'venues', 0,
    'venueEvents', 0
  );
END;
$$;
