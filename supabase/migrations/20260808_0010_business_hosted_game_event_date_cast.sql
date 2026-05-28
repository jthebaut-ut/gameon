-- Ensure the hosted-game RPC writes text date params into the date-typed venue_events.event_date column.
-- The RPC signature stays unchanged for PostgREST named-parameter compatibility.

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

  IF p_venue_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id = p_venue_id
      AND lower(btrim(coalesce(v.admin_status, ''))) = 'plan_locked'
      AND (
        v.business_id = p_business_id
        OR (
          v.business_id IS NULL
          AND (
            v.owner_user_id = auth.uid()
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
        )
      )
  ) THEN
    RAISE EXCEPTION 'This venue is locked under the current business plan. Upgrade to FanGeo Pro to host games here.'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_venue_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id = p_venue_id
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        v.business_id = p_business_id
        OR (
          v.business_id IS NULL
          AND (
            v.owner_user_id = auth.uid()
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
    p_event_date::date,
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

GRANT EXECUTE ON FUNCTION public.create_business_hosted_game(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, boolean, boolean, text, text, text, text, text, boolean, boolean, text, text, integer) TO authenticated;

COMMENT ON FUNCTION public.create_business_hosted_game(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, boolean, boolean, text, text, text, text, text, boolean, boolean, text, text, integer) IS
  'Creates a business hosted venue_event after owner auth and server monthly host limit checks. PostgREST named params use the p_* signature.';

NOTIFY pgrst, 'reload schema';
