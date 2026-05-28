-- Qualify venue submission RPC column references to avoid PL/pgSQL
-- output-parameter ambiguity such as: column reference "id" is ambiguous.

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

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
      AND v.admin_status = 'active'
      AND (
        (p_business_id IS NOT NULL AND v.business_id IS NOT DISTINCT FROM p_business_id)
        OR (
          p_business_id IS NULL
          AND v.business_id IS NULL
          AND lower(trim(COALESCE(v.owner_email, ''))) = lower(trim(COALESCE(p_owner_email, '')))
        )
      )
  )
  INTO same_biz_venue;

  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims AS c
    WHERE c.venue_identity_key = k
      AND (p_exclude_claim_id IS NULL OR c.id <> p_exclude_claim_id)
      AND lower(trim(COALESCE(c.approval_status, ''))) = 'approved'
      AND (c.business_id IS NOT DISTINCT FROM p_business_id)
      AND lower(trim(COALESCE(c.owner_email, ''))) = lower(trim(COALESCE(p_owner_email, '')))
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
      AND (p_exclude_claim_id IS NULL OR c.id <> p_exclude_claim_id)
      AND public.gameon_venue_claim_is_open_pending(c.approval_status)
      AND (c.business_id IS NOT DISTINCT FROM p_business_id)
      AND lower(trim(COALESCE(c.owner_email, ''))) = lower(trim(COALESCE(p_owner_email, '')))
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
      AND v.admin_status = 'active'
      AND NOT (
        (p_business_id IS NOT NULL AND v.business_id IS NOT DISTINCT FROM p_business_id)
        OR (
          p_business_id IS NULL
          AND v.business_id IS NULL
          AND lower(trim(COALESCE(v.owner_email, ''))) = lower(trim(COALESCE(p_owner_email, '')))
        )
      )
  )
  INTO other_active_venue;

  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims AS c
    WHERE c.venue_identity_key = k
      AND (p_exclude_claim_id IS NULL OR c.id <> p_exclude_claim_id)
      AND (
        public.gameon_venue_claim_is_open_pending(c.approval_status)
        OR lower(trim(COALESCE(c.approval_status, ''))) = 'approved'
      )
      AND NOT (
        (c.business_id IS NOT DISTINCT FROM p_business_id)
        AND lower(trim(COALESCE(c.owner_email, ''))) = lower(trim(COALESCE(p_owner_email, '')))
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

CREATE OR REPLACE FUNCTION public.create_business_venue_claim(
  p_business_id uuid,
  p_owner_email text,
  p_venue_id uuid,
  p_venue_name text,
  p_venue_address text,
  p_venue_address_line2 text,
  p_venue_city text,
  p_venue_state text,
  p_venue_country text,
  p_venue_zip_code text,
  p_venue_formatted_address text,
  p_venue_latitude double precision,
  p_venue_longitude double precision,
  p_venue_phone text,
  p_venue_website text,
  p_venue_description text,
  p_venue_features text,
  p_screen_count integer,
  p_serves_food boolean,
  p_has_wifi boolean,
  p_has_garden boolean,
  p_has_projector boolean,
  p_pet_friendly boolean,
  p_cover_photo_url text,
  p_menu_photo_url text,
  p_proof_note text
)
RETURNS TABLE (
  id uuid,
  created_at timestamptz,
  approval_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_owner_email text;
  v_debug_section text := 'businessLookup';
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  SELECT b.*
    INTO v_business
  FROM public.businesses AS b
  WHERE b.id = p_business_id
    AND lower(btrim(coalesce(b.admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0002';
  END IF;

  v_debug_section := 'ownershipCheck';
  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized to create venue claims for this business.' USING ERRCODE = '42501';
  END IF;

  v_debug_section := 'entitlementCheck';
  IF NOT public.can_business_create_venue(p_business_id) THEN
    RAISE EXCEPTION 'Free businesses can list 5 active venues. Upgrade to Business Pro for unlimited locations.'
      USING ERRCODE = 'P0001';
  END IF;

  v_debug_section := 'ownerEmailNormalize';
  v_owner_email := lower(btrim(coalesce(NULLIF(p_owner_email, ''), v_business.owner_email, auth.jwt() ->> 'email', '')));
  IF NULLIF(v_owner_email, '') IS NULL THEN
    RAISE EXCEPTION 'Business owner email is required.' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.business_entitlement_gate', 'create_business_venue_claim', true);

  v_debug_section := 'insertVenueClaim';
  RETURN QUERY
  INSERT INTO public.venue_claims AS vc (
    owner_email,
    business_id,
    venue_id,
    venue_name,
    venue_address,
    venue_address_line2,
    venue_city,
    venue_state,
    venue_country,
    venue_zip_code,
    venue_formatted_address,
    venue_latitude,
    venue_longitude,
    venue_phone,
    venue_website,
    venue_description,
    venue_features,
    screen_count,
    serves_food,
    has_wifi,
    has_garden,
    has_projector,
    pet_friendly,
    cover_photo_url,
    menu_photo_url,
    proof_note
  )
  VALUES (
    v_owner_email,
    p_business_id,
    p_venue_id,
    p_venue_name,
    p_venue_address,
    p_venue_address_line2,
    p_venue_city,
    p_venue_state,
    COALESCE(NULLIF(p_venue_country, ''), 'USA'),
    p_venue_zip_code,
    p_venue_formatted_address,
    p_venue_latitude,
    p_venue_longitude,
    p_venue_phone,
    p_venue_website,
    p_venue_description,
    p_venue_features,
    COALESCE(p_screen_count, 0),
    COALESCE(p_serves_food, false),
    COALESCE(p_has_wifi, false),
    COALESCE(p_has_garden, false),
    COALESCE(p_has_projector, false),
    COALESCE(p_pet_friendly, false),
    p_cover_photo_url,
    p_menu_photo_url,
    p_proof_note
  )
  RETURNING vc.id, vc.created_at, vc.approval_status;
EXCEPTION WHEN OTHERS THEN
  RAISE LOG '[VenueSubmissionRPCDebug] rpcName=% failingQuerySection=% postgresError=% businessId=% venueId=%',
    'create_business_venue_claim',
    v_debug_section,
    SQLERRM,
    p_business_id,
    p_venue_id;
  RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.create_business_venue_claim(uuid, text, uuid, text, text, text, text, text, text, text, text, double precision, double precision, text, text, text, text, integer, boolean, boolean, boolean, boolean, boolean, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_business_venue_claim(uuid, text, uuid, text, text, text, text, text, text, text, text, double precision, double precision, text, text, text, text, integer, boolean, boolean, boolean, boolean, boolean, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.create_business_venue_claim(uuid, text, uuid, text, text, text, text, text, text, text, text, double precision, double precision, text, text, text, text, integer, boolean, boolean, boolean, boolean, boolean, text, text, text) IS
  'Creates a business add-location venue_claim after owner auth and server active venue limit checks. Column references are qualified to avoid PL/pgSQL output parameter ambiguity.';

NOTIFY pgrst, 'reload schema';
