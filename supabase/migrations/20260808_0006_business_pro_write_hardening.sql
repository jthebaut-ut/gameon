-- Business Pro entitlement write hardening.
-- New app versions create business venue claims and hosted games through RPCs;
-- trigger guards block old direct client inserts for those business write paths.

CREATE OR REPLACE FUNCTION public.business_entitlement_gate_is_rpc(p_operation text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT current_setting('app.business_entitlement_gate', true) = p_operation
    OR auth.role() = 'service_role'
    OR session_user IN ('postgres', 'service_role', 'supabase_admin');
$$;

CREATE OR REPLACE FUNCTION public.business_entitlement_caller_owns_business(p_business_id uuid)
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
      AND lower(btrim(coalesce(b.admin_status, ''))) = 'active'
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

-- Count active venues plus open add-location claims so free businesses cannot
-- queue multiple pending locations before admin approval.
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

  WITH active_business_venues AS (
    SELECT DISTINCT v.id
    FROM public.venues v
    WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        v.business_id = p_business_id
        OR (
          v_business.owner_email IS NOT NULL
          AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(v_business.owner_email))
        )
      )
  ),
  open_add_location_claims AS (
    SELECT DISTINCT c.id
    FROM public.venue_claims c
    WHERE c.business_id = p_business_id
      AND c.venue_id IS NULL
      AND public.gameon_venue_claim_is_open_pending(c.approval_status)
  )
  SELECT (SELECT count(*) FROM active_business_venues)::integer
       + (SELECT count(*) FROM open_add_location_claims)::integer
    INTO v_venues_used;

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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id
    AND lower(btrim(coalesce(admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized to create venue claims for this business.' USING ERRCODE = '42501';
  END IF;

  IF NOT public.can_business_create_venue(p_business_id) THEN
    RAISE EXCEPTION 'Free businesses can list 5 venues. Upgrade to Business Pro for unlimited venue listings.'
      USING ERRCODE = 'P0001';
  END IF;

  v_owner_email := lower(btrim(coalesce(NULLIF(p_owner_email, ''), v_business.owner_email, auth.jwt() ->> 'email', '')));
  IF NULLIF(v_owner_email, '') IS NULL THEN
    RAISE EXCEPTION 'Business owner email is required.' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.business_entitlement_gate', 'create_business_venue_claim', true);

  RETURN QUERY
  INSERT INTO public.venue_claims (
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
  RETURNING venue_claims.id, venue_claims.created_at, venue_claims.approval_status;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_business_hosted_game(
  p_business_id uuid,
  p_venue_id uuid,
  p_owner_email text,
  p_venue_name text,
  p_event_title text,
  p_sport text,
  p_home_team text,
  p_away_team text,
  p_external_league text,
  p_event_date text,
  p_event_time text,
  p_external_game_id text,
  p_external_source text,
  p_imported_from_api boolean,
  p_sound_on boolean,
  p_audio_type text,
  p_drink_special text,
  p_cover_charge text,
  p_expected_crowd text,
  p_available_seating text,
  p_reservations_available boolean,
  p_waitlist_available boolean,
  p_admin_status text,
  p_scheduled_start_at text,
  p_cleanup_delay_hours integer
)
RETURNS SETOF public.venue_events
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_owner_email text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id
    AND lower(btrim(coalesce(admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized to create hosted games for this business.' USING ERRCODE = '42501';
  END IF;

  IF NOT public.can_business_host_game(p_business_id) THEN
    RAISE EXCEPTION 'Free businesses can host 5 games per month. Upgrade to Business Pro for unlimited hosting.'
      USING ERRCODE = 'P0001';
  END IF;

  v_owner_email := lower(btrim(coalesce(NULLIF(p_owner_email, ''), v_business.owner_email, auth.jwt() ->> 'email', '')));
  IF NULLIF(v_owner_email, '') IS NULL THEN
    RAISE EXCEPTION 'Business owner email is required.' USING ERRCODE = '22023';
  END IF;

  IF p_venue_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id = p_venue_id
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        v.business_id = p_business_id
        OR v.owner_user_id = auth.uid()
        OR lower(btrim(coalesce(v.owner_email, ''))) = v_owner_email
        OR EXISTS (
          SELECT 1
          FROM public.venue_claims c
          WHERE c.venue_id = v.id
            AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
            AND (
              c.business_id = p_business_id
              OR lower(btrim(coalesce(c.owner_email, ''))) = v_owner_email
            )
        )
      )
  ) THEN
    RAISE EXCEPTION 'Not authorized to create hosted games for this venue.' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.business_entitlement_gate', 'create_business_hosted_game', true);

  RETURN QUERY
  INSERT INTO public.venue_events (
    venue_id,
    owner_email,
    venue_name,
    event_title,
    sport,
    home_team,
    away_team,
    external_league,
    event_date,
    event_time,
    external_game_id,
    external_source,
    imported_from_api,
    sound_on,
    audio_type,
    drink_special,
    cover_charge,
    expected_crowd,
    available_seating,
    reservations_available,
    waitlist_available,
    admin_status,
    scheduled_start_at,
    cleanup_delay_hours
  )
  VALUES (
    p_venue_id,
    v_owner_email,
    p_venue_name,
    p_event_title,
    p_sport,
    p_home_team,
    p_away_team,
    p_external_league,
    p_event_date,
    p_event_time,
    p_external_game_id,
    p_external_source,
    COALESCE(p_imported_from_api, false),
    COALESCE(p_sound_on, true),
    COALESCE(NULLIF(p_audio_type, ''), 'full'),
    COALESCE(p_drink_special, ''),
    COALESCE(p_cover_charge, ''),
    COALESCE(p_expected_crowd, ''),
    COALESCE(p_available_seating, ''),
    COALESCE(p_reservations_available, false),
    COALESCE(p_waitlist_available, false),
    COALESCE(NULLIF(p_admin_status, ''), 'active'),
    NULLIF(p_scheduled_start_at, '')::timestamptz,
    COALESCE(p_cleanup_delay_hours, 12)
  )
  RETURNING *;
END;
$$;

CREATE OR REPLACE FUNCTION public.block_direct_business_venue_claim_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.business_id IS NOT NULL
     AND NEW.venue_id IS NULL
     AND NOT public.business_entitlement_gate_is_rpc('create_business_venue_claim') THEN
    RAISE EXCEPTION 'Business venue claims must be created through create_business_venue_claim.'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_direct_business_venue_claim_insert ON public.venue_claims;
CREATE TRIGGER trg_block_direct_business_venue_claim_insert
  BEFORE INSERT ON public.venue_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.block_direct_business_venue_claim_insert();

CREATE OR REPLACE FUNCTION public.block_direct_business_hosted_game_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_business_hosted boolean := false;
BEGIN
  SELECT (
    EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id = NEW.venue_id
      AND (
        v.business_id IS NOT NULL
        OR v.owner_user_id IS NOT NULL
        OR EXISTS (
          SELECT 1
          FROM public.businesses b
          WHERE lower(btrim(coalesce(b.owner_email, ''))) = lower(btrim(coalesce(v.owner_email, '')))
            AND NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
            AND lower(btrim(coalesce(b.admin_status, ''))) = 'active'
        )
      )
    )
    OR EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE lower(btrim(coalesce(b.owner_email, ''))) = lower(btrim(coalesce(NEW.owner_email, '')))
      AND NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
      AND lower(btrim(coalesce(b.admin_status, ''))) = 'active'
    )
  )
    INTO v_is_business_hosted;

  IF v_is_business_hosted
     AND NOT public.business_entitlement_gate_is_rpc('create_business_hosted_game') THEN
    RAISE EXCEPTION 'Business hosted games must be created through create_business_hosted_game.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_direct_business_hosted_game_insert ON public.venue_events;
CREATE TRIGGER trg_block_direct_business_hosted_game_insert
  BEFORE INSERT ON public.venue_events
  FOR EACH ROW
  EXECUTE FUNCTION public.block_direct_business_hosted_game_insert();

REVOKE ALL ON FUNCTION public.business_entitlement_gate_is_rpc(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_entitlement_caller_owns_business(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_business_venue_claim(uuid, text, uuid, text, text, text, text, text, text, text, text, double precision, double precision, text, text, text, text, integer, boolean, boolean, boolean, boolean, boolean, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_business_hosted_game(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, boolean, boolean, text, text, text, text, text, boolean, boolean, text, text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_business_venue_claim(uuid, text, uuid, text, text, text, text, text, text, text, text, double precision, double precision, text, text, text, text, integer, boolean, boolean, boolean, boolean, boolean, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_business_hosted_game(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, boolean, boolean, text, text, text, text, text, boolean, boolean, text, text, integer) TO authenticated;

COMMENT ON FUNCTION public.create_business_venue_claim(uuid, text, uuid, text, text, text, text, text, text, text, text, double precision, double precision, text, text, text, text, integer, boolean, boolean, boolean, boolean, boolean, text, text, text) IS
  'Creates a business add-location venue_claim after owner auth and server entitlement limit checks.';
COMMENT ON FUNCTION public.create_business_hosted_game(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, boolean, boolean, text, text, text, text, text, boolean, boolean, text, text, integer) IS
  'Creates a business hosted venue_event after owner auth and server monthly host limit checks.';
