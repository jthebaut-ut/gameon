-- Permanent Apple App Store review demo venue + hosted game (idempotent).
--
-- Requires: 20260808_0043_apple_review_demo_accounts.sql (businessdemo@businessdemo.com).
--
-- Venue:  FanGeo Sports Bar Demo (San Francisco)
-- Event:  France vs USA Watch Party (starts 7 days from migration run, 7:00 PM America/Los_Angeles)
--
-- Claim insert only when neither demo venue nor demo claim exists (identity guard).
-- Existing approved claims are left untouched — venue ownership is on public.venues.

DO $$
DECLARE
  v_biz_email constant text := 'businessdemo@businessdemo.com';
  v_venue_name constant text := 'FanGeo Sports Bar Demo';

  v_venue_seed_id constant uuid := 'a0000004-0004-4004-8004-000000000004'::uuid;
  v_claim_seed_id constant uuid := 'a0000005-0005-4005-8005-000000000005'::uuid;
  v_event_seed_id constant uuid := 'a0000006-0006-4006-8006-000000000006'::uuid;

  v_event_external_source constant text := 'apple_review_demo';
  v_event_external_game_id constant text := 'france_usa_watch_party';

  v_biz_user_id uuid;
  v_business_id uuid;
  v_venue_id uuid;
  v_claim_id uuid;
  v_event_id uuid;
  v_now timestamptz := now();

  v_had_venue boolean := false;
  v_had_claim boolean := false;
  v_claim_inserted boolean := false;
  v_event_start timestamptz;
  v_event_date date;
  v_event_time text := '7:00 PM';
BEGIN
  SELECT u.id
    INTO v_biz_user_id
  FROM auth.users u
  WHERE lower(btrim(u.email)) = v_biz_email
  LIMIT 1;

  IF v_biz_user_id IS NULL THEN
    RAISE EXCEPTION
      'Apple review demo business auth user missing (%). Apply 20260808_0043_apple_review_demo_accounts.sql first.',
      v_biz_email;
  END IF;

  SELECT b.id
    INTO v_business_id
  FROM public.businesses b
  WHERE b.owner_user_id = v_biz_user_id
     OR lower(btrim(coalesce(b.owner_email, ''))) = v_biz_email
  ORDER BY b.created_at NULLS LAST
  LIMIT 1;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION
      'Apple review demo business row missing for %. Apply 20260808_0043_apple_review_demo_accounts.sql first.',
      v_biz_email;
  END IF;

  v_event_start := (
    (timezone('America/Los_Angeles', v_now)::date + 7)::timestamp + time '19:00'
  ) AT TIME ZONE 'America/Los_Angeles';
  v_event_date := timezone('America/Los_Angeles', v_event_start)::date;

  -- -------------------------------------------------------------------------
  -- Resolve existing demo venue (never create a second row for this business).
  -- -------------------------------------------------------------------------
  SELECT v.id
    INTO v_venue_id
  FROM public.venues v
  WHERE v.id = v_venue_seed_id
     OR (
       v.business_id IS NOT DISTINCT FROM v_business_id
       AND v.owner_user_id IS NOT DISTINCT FROM v_biz_user_id
       AND lower(btrim(coalesce(v.venue_name, ''))) = lower(v_venue_name)
     )
  ORDER BY (v.id = v_venue_seed_id) DESC, v.created_at NULLS LAST
  LIMIT 1;

  v_had_venue := v_venue_id IS NOT NULL;

  -- -------------------------------------------------------------------------
  -- Resolve existing approved demo claim (never create a second approved claim).
  -- -------------------------------------------------------------------------
  SELECT c.id
    INTO v_claim_id
  FROM public.venue_claims c
  WHERE c.id = v_claim_seed_id
     OR (
       c.business_id IS NOT DISTINCT FROM v_business_id
       AND lower(btrim(coalesce(c.owner_email, ''))) = v_biz_email
       AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
       AND lower(btrim(coalesce(c.venue_name, ''))) = lower(v_venue_name)
     )
  ORDER BY (c.id = v_claim_seed_id) DESC, c.created_at NULLS LAST
  LIMIT 1;

  v_had_claim := v_claim_id IS NOT NULL;

  -- Claim insert only when neither demo venue nor demo claim exists.
  IF NOT v_had_claim AND NOT v_had_venue THEN
    INSERT INTO public.venue_claims (
      id,
      owner_email,
      business_id,
      venue_id,
      venue_name,
      venue_address,
      venue_city,
      venue_state,
      venue_country,
      venue_zip_code,
      venue_formatted_address,
      venue_latitude,
      venue_longitude,
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
      proof_note,
      approval_status
    ) VALUES (
      v_claim_seed_id,
      v_biz_email,
      v_business_id,
      NULL,
      v_venue_name,
      '1 Market St',
      'San Francisco',
      'CA',
      'United States',
      '94105',
      'San Francisco, California, United States',
      37.7946,
      -122.3959,
      'Demo venue used for App Store review.',
      'Soccer,Big screens,Watch parties',
      12,
      true,
      true,
      false,
      true,
      false,
      '',
      '',
      'Permanent Apple App Store review demo venue.',
      'approved'
    );
    v_claim_id := v_claim_seed_id;
    v_claim_inserted := true;
  ELSIF NOT v_had_claim AND v_had_venue THEN
    RAISE NOTICE '[AppleReviewDemoVenue] demo venue exists without claim row; skipping claim insert (identity guard; venue row is authoritative)';
  ELSIF v_had_claim THEN
    RAISE NOTICE '[AppleReviewDemoVenue] approved demo claim exists (id=%); leaving claim row unchanged', v_claim_id;
  END IF;

  -- -------------------------------------------------------------------------
  -- Venue upsert
  -- -------------------------------------------------------------------------
  IF NOT v_had_venue THEN
    v_venue_id := v_venue_seed_id;
    INSERT INTO public.venues (
      id,
      owner_email,
      owner_user_id,
      business_id,
      origin_type,
      admin_status,
      venue_name,
      address,
      address_line1,
      city,
      state,
      country,
      formatted_address,
      zip_code,
      description,
      features,
      screen_count,
      serves_food,
      has_wifi,
      has_garden,
      has_projector,
      pet_friendly,
      latitude,
      longitude,
      cover_photo_url,
      menu_photo_url,
      cover_photo_thumbnail_url,
      menu_photo_thumbnail_url
    ) VALUES (
      v_venue_id,
      v_biz_email,
      v_biz_user_id,
      v_business_id,
      'business',
      'active',
      v_venue_name,
      '1 Market St',
      '1 Market St',
      'San Francisco',
      'CA',
      'United States',
      'San Francisco, California, United States',
      '94105',
      'Demo venue used for App Store review.',
      'Soccer,Big screens,Watch parties',
      12,
      true,
      true,
      false,
      true,
      false,
      37.7946,
      -122.3959,
      '',
      '',
      NULL,
      NULL
    );
  ELSE
    UPDATE public.venues
    SET
      owner_email = v_biz_email,
      owner_user_id = v_biz_user_id,
      business_id = v_business_id,
      origin_type = 'business',
      admin_status = 'active',
      venue_name = v_venue_name,
      address = '1 Market St',
      address_line1 = '1 Market St',
      city = 'San Francisco',
      state = 'CA',
      country = 'United States',
      formatted_address = 'San Francisco, California, United States',
      zip_code = '94105',
      description = 'Demo venue used for App Store review.',
      features = 'Soccer,Big screens,Watch parties',
      screen_count = 12,
      serves_food = true,
      has_wifi = true,
      has_garden = false,
      has_projector = true,
      pet_friendly = false,
      latitude = 37.7946,
      longitude = -122.3959
    WHERE id = v_venue_id;
  END IF;

  -- Link a claim created in this run only (venue_id is not identity-guarded on UPDATE).
  IF v_claim_inserted AND v_claim_id IS NOT NULL THEN
    UPDATE public.venue_claims
    SET venue_id = v_venue_id
    WHERE id = v_claim_id
      AND venue_id IS DISTINCT FROM v_venue_id;
  END IF;

  -- -------------------------------------------------------------------------
  -- Demo hosted game upsert (keyed by external_source + external_game_id)
  -- -------------------------------------------------------------------------
  SELECT ve.id
    INTO v_event_id
  FROM public.venue_events ve
  WHERE ve.id = v_event_seed_id
     OR (
       lower(btrim(coalesce(ve.external_source, ''))) = v_event_external_source
       AND lower(btrim(coalesce(ve.external_game_id, ''))) = v_event_external_game_id
     )
  ORDER BY (ve.id = v_event_seed_id) DESC, ve.created_at NULLS LAST
  LIMIT 1;

  IF v_event_id IS NULL THEN
    v_event_id := v_event_seed_id;
    INSERT INTO public.venue_events (
      id,
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
    ) VALUES (
      v_event_id,
      v_venue_id,
      v_biz_email,
      v_venue_name,
      'France vs USA Watch Party',
      'Soccer',
      'France',
      'USA',
      '',
      v_event_date,
      v_event_time,
      v_event_external_game_id,
      v_event_external_source,
      false,
      true,
      'full',
      'Demo event used for App Store review.',
      '',
      '',
      '',
      false,
      false,
      'active',
      v_event_start,
      12
    );
  ELSE
    UPDATE public.venue_events
    SET
      venue_id = v_venue_id,
      owner_email = v_biz_email,
      venue_name = v_venue_name,
      event_title = 'France vs USA Watch Party',
      sport = 'Soccer',
      home_team = 'France',
      away_team = 'USA',
      external_league = '',
      event_date = v_event_date,
      event_time = v_event_time,
      external_game_id = v_event_external_game_id,
      external_source = v_event_external_source,
      imported_from_api = false,
      sound_on = true,
      audio_type = 'full',
      drink_special = 'Demo event used for App Store review.',
      cover_charge = '',
      expected_crowd = '',
      available_seating = '',
      reservations_available = false,
      waitlist_available = false,
      admin_status = 'active',
      scheduled_start_at = v_event_start,
      cleanup_delay_hours = 12
    WHERE id = v_event_id;
  END IF;

  RAISE NOTICE '[AppleReviewDemoVenue] business_id=% venue_id=% claim_id=% claim_inserted=% had_venue=% had_claim=% event_id=% event_start=%',
    v_business_id, v_venue_id, v_claim_id, v_claim_inserted, v_had_venue, v_had_claim, v_event_id, v_event_start;
END $$;

-- Read-only verification view for admin / post-migration checks.
CREATE OR REPLACE VIEW public.apple_review_demo_venue_verification AS
WITH biz AS (
  SELECT
    u.id AS owner_user_id,
    lower(btrim(u.email)) AS owner_email,
    b.id AS business_id,
    b.display_name AS business_name
  FROM auth.users u
  JOIN public.businesses b
    ON b.owner_user_id = u.id
   AND lower(btrim(coalesce(b.admin_status, ''))) = 'active'
  WHERE lower(btrim(u.email)) = 'businessdemo@businessdemo.com'
  LIMIT 1
),
venue AS (
  SELECT
    v.id,
    v.venue_name,
    v.owner_email,
    v.owner_user_id,
    v.business_id,
    v.origin_type,
    v.admin_status,
    v.description,
    v.formatted_address,
    v.latitude,
    v.longitude
  FROM public.venues v
  JOIN biz ON biz.business_id = v.business_id
  WHERE v.owner_user_id IS NOT DISTINCT FROM biz.owner_user_id
    AND lower(btrim(coalesce(v.venue_name, ''))) = lower('FanGeo Sports Bar Demo')
    AND lower(btrim(coalesce(v.admin_status, ''))) = 'active'
  ORDER BY v.created_at NULLS LAST
  LIMIT 1
),
claim AS (
  SELECT
    c.id,
    c.venue_id,
    c.business_id,
    c.owner_email,
    c.approval_status
  FROM public.venue_claims c
  JOIN biz ON biz.business_id = c.business_id
  WHERE lower(btrim(coalesce(c.owner_email, ''))) = 'businessdemo@businessdemo.com'
    AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
    AND lower(btrim(coalesce(c.venue_name, ''))) = lower('FanGeo Sports Bar Demo')
  ORDER BY c.created_at NULLS LAST
  LIMIT 1
),
event_row AS (
  SELECT
    ve.id,
    ve.venue_id,
    ve.event_title,
    ve.sport,
    ve.home_team,
    ve.away_team,
    ve.admin_status,
    ve.scheduled_start_at,
    ve.external_source,
    ve.external_game_id,
    ve.sound_on,
    ve.drink_special AS event_description
  FROM public.venue_events ve
  WHERE lower(btrim(coalesce(ve.external_source, ''))) = 'apple_review_demo'
    AND lower(btrim(coalesce(ve.external_game_id, ''))) = 'france_usa_watch_party'
    AND lower(btrim(coalesce(ve.admin_status, ''))) = 'active'
  ORDER BY ve.scheduled_start_at DESC NULLS LAST
  LIMIT 1
)
SELECT
  'business_owner_linked' AS check_name,
  EXISTS (SELECT 1 FROM biz) AS passed,
  (SELECT owner_email FROM biz LIMIT 1) AS detail
UNION ALL
SELECT
  'venue_exists_active',
  EXISTS (SELECT 1 FROM venue),
  (SELECT venue_name FROM venue LIMIT 1)
UNION ALL
SELECT
  'single_demo_venue',
  coalesce((SELECT count(*) FROM public.venues v JOIN biz ON biz.business_id = v.business_id
    WHERE v.owner_user_id IS NOT DISTINCT FROM biz.owner_user_id
      AND lower(btrim(coalesce(v.venue_name, ''))) = lower('FanGeo Sports Bar Demo')
      AND lower(btrim(coalesce(v.admin_status, ''))) = 'active') = 1, false),
  (SELECT id::text FROM venue LIMIT 1)
UNION ALL
SELECT
  'venue_has_coordinates',
  coalesce((
    SELECT latitude IS NOT NULL AND longitude IS NOT NULL
    FROM venue
    LIMIT 1
  ), false),
  (SELECT latitude::text || ',' || longitude::text FROM venue LIMIT 1)
UNION ALL
SELECT
  'venue_business_owned',
  coalesce((
    SELECT business_id IS NOT NULL
      AND owner_user_id IS NOT NULL
      AND lower(btrim(coalesce(owner_email, ''))) = 'businessdemo@businessdemo.com'
      AND origin_type = 'business'
    FROM venue
    LIMIT 1
  ), false),
  (SELECT business_id::text FROM venue LIMIT 1)
UNION ALL
SELECT
  'venue_claim_approved',
  EXISTS (SELECT 1 FROM claim),
  (SELECT approval_status FROM claim LIMIT 1)
UNION ALL
SELECT
  'single_demo_claim',
  coalesce((SELECT count(*) FROM public.venue_claims c JOIN biz ON biz.business_id = c.business_id
    WHERE lower(btrim(coalesce(c.owner_email, ''))) = 'businessdemo@businessdemo.com'
      AND lower(btrim(coalesce(c.approval_status, ''))) = 'approved'
      AND lower(btrim(coalesce(c.venue_name, ''))) = lower('FanGeo Sports Bar Demo')) <= 1, false),
  (SELECT id::text FROM claim LIMIT 1)
UNION ALL
SELECT
  'claim_linked_or_venue_owned',
  coalesce((
    SELECT
      venue.business_id IS NOT NULL
      AND venue.owner_user_id IS NOT NULL
      AND (
        NOT EXISTS (SELECT 1 FROM claim)
        OR claim.venue_id IS NOT DISTINCT FROM venue.id
      )
    FROM venue
    LEFT JOIN claim ON true
    LIMIT 1
  ), false),
  coalesce((SELECT id::text FROM claim LIMIT 1), 'claim_optional')
UNION ALL
SELECT
  'demo_event_exists',
  EXISTS (SELECT 1 FROM event_row),
  (SELECT event_title FROM event_row LIMIT 1)
UNION ALL
SELECT
  'demo_event_future_start',
  coalesce((
    SELECT scheduled_start_at > now()
    FROM event_row
    LIMIT 1
  ), false),
  (SELECT scheduled_start_at::text FROM event_row LIMIT 1)
UNION ALL
SELECT
  'demo_event_predictions_ready',
  coalesce((
    SELECT home_team IS NOT NULL
      AND away_team IS NOT NULL
      AND btrim(home_team) <> ''
      AND btrim(away_team) <> ''
      AND lower(btrim(coalesce(sport, ''))) = 'soccer'
    FROM event_row
    LIMIT 1
  ), false),
  (SELECT home_team || ' vs ' || away_team FROM event_row LIMIT 1)
UNION ALL
SELECT
  'demo_event_chat_ready',
  coalesce((SELECT sound_on FROM event_row LIMIT 1), false),
  'sound_on=true (fan chat enabled for active venue events)'
UNION ALL
SELECT
  'demo_event_description',
  coalesce((
    SELECT btrim(coalesce(event_description, '')) = 'Demo event used for App Store review.'
    FROM event_row
    LIMIT 1
  ), false),
  (SELECT event_description FROM event_row LIMIT 1);

COMMENT ON VIEW public.apple_review_demo_venue_verification IS
  'Post-migration checks for permanent Apple review demo venue + hosted game. Query after applying 20260808_0044.';

REVOKE ALL ON public.apple_review_demo_venue_verification FROM PUBLIC;
GRANT SELECT ON public.apple_review_demo_venue_verification TO service_role;

NOTIFY pgrst, 'reload schema';
