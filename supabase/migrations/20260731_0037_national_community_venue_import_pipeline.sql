-- National community venue import pipeline.
--
-- Backend-only import architecture:
-- - creates staging table
-- - creates normalization helpers
-- - creates duplicate/validation helpers
-- - creates explicit promote-to-production RPC
--
-- This migration does not import, update, delete, or backfill existing venue
-- data. Promotion happens only when service/admin code calls
-- public.promote_community_venue_import_batch(...).

CREATE OR REPLACE FUNCTION public.community_venue_import_normalize_venue_name(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT public.gameon_normalize_venue_text(input);
$$;

CREATE OR REPLACE FUNCTION public.community_venue_import_normalize_address(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT public.gameon_normalize_venue_text(input);
$$;

CREATE OR REPLACE FUNCTION public.community_venue_import_identity_key(
  p_name text,
  p_address text,
  p_city text,
  p_state text,
  p_zip text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT public.gameon_venue_identity_key(p_name, p_address, p_city, p_state, p_zip);
$$;

CREATE TABLE IF NOT EXISTS public.community_venue_import_staging (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_batch_id text NOT NULL,
  source_row_number integer,
  community_source text NOT NULL,
  community_source_id text,
  community_seeded_at timestamptz,
  community_curated_by text,

  venue_name text NOT NULL,
  address text NOT NULL,
  address_line1 text,
  address_line2 text,
  city text NOT NULL,
  state text NOT NULL,
  zip_code text NOT NULL,
  country text NOT NULL DEFAULT 'USA',
  region text,
  postal_code text,
  formatted_address text,
  latitude double precision NOT NULL,
  longitude double precision NOT NULL,

  phone text,
  public_email text,
  website text,
  description text,
  description_is_basic_public_listing boolean NOT NULL DEFAULT false,

  origin_type text NOT NULL DEFAULT 'community',
  business_id uuid,
  owner_user_id uuid,
  owner_email text,
  admin_status text NOT NULL DEFAULT 'active',

  cover_photo_url text,
  menu_photo_url text,
  cover_photo_thumbnail_url text,
  menu_photo_thumbnail_url text,
  features text,
  screen_count integer,
  serves_food boolean,
  has_wifi boolean,
  has_garden boolean,
  has_projector boolean,
  pet_friendly boolean,
  supporter_country text,

  community_provenance jsonb NOT NULL DEFAULT '{}'::jsonb,

  normalized_venue_name text GENERATED ALWAYS AS (
    public.community_venue_import_normalize_venue_name(venue_name)
  ) STORED,
  normalized_address text GENERATED ALWAYS AS (
    public.community_venue_import_normalize_address(address)
  ) STORED,
  normalized_city text GENERATED ALWAYS AS (
    public.gameon_normalize_venue_text(city)
  ) STORED,
  normalized_state text GENERATED ALWAYS AS (
    public.gameon_normalize_venue_state(state)
  ) STORED,
  venue_identity_key text GENERATED ALWAYS AS (
    public.community_venue_import_identity_key(venue_name, address, city, state, zip_code)
  ) STORED,

  import_status text NOT NULL DEFAULT 'pending'
    CHECK (import_status IN ('pending', 'invalid', 'duplicate', 'ready', 'promoted', 'skipped')),
  duplicate_reason text,
  promoted_venue_id uuid,
  promoted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.community_venue_import_staging IS
  'Staging table for nationwide community venue imports. Rows must be identity/provenance-only and must not use fake owner/business accounts.';

COMMENT ON COLUMN public.community_venue_import_staging.import_batch_id IS
  'Required import batch identifier used to validate and promote a controlled group of staged community venues.';

COMMENT ON COLUMN public.community_venue_import_staging.import_status IS
  'Import lifecycle: pending, invalid, duplicate, ready, promoted, or skipped. Promotion only inserts ready rows.';

COMMENT ON COLUMN public.community_venue_import_staging.duplicate_reason IS
  'Reason a staged row was marked duplicate or invalid, including identity-key or normalized name/address collisions.';

COMMENT ON COLUMN public.community_venue_import_staging.public_email IS
  'Optional real public venue email captured for provenance. This is not an owner_email and grants no authority.';

COMMENT ON COLUMN public.community_venue_import_staging.community_seeded_at IS
  'Optional source/import timestamp to carry into public.venues.community_seeded_at during promotion.';

COMMENT ON COLUMN public.community_venue_import_staging.community_curated_by IS
  'Optional importer/admin/process marker to carry into public.venues.community_curated_by during promotion.';

COMMENT ON COLUMN public.community_venue_import_staging.description_is_basic_public_listing IS
  'When true, description is basic public listing text. Promotional/business-authored details are not allowed in seed imports.';

COMMENT ON COLUMN public.community_venue_import_staging.community_provenance IS
  'Raw source/import metadata. Provenance only; must not contain fake business ownership authority.';

CREATE INDEX IF NOT EXISTS idx_community_venue_import_staging_batch_status
  ON public.community_venue_import_staging (import_batch_id, import_status);

CREATE INDEX IF NOT EXISTS idx_community_venue_import_staging_identity
  ON public.community_venue_import_staging (venue_identity_key);

CREATE INDEX IF NOT EXISTS idx_community_venue_import_staging_normalized_location
  ON public.community_venue_import_staging (
    normalized_venue_name,
    normalized_address,
    normalized_city,
    normalized_state
  );

CREATE OR REPLACE FUNCTION public.community_venue_import_validation_errors(
  p_row public.community_venue_import_staging
)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
  SELECT array_remove(ARRAY[
    CASE WHEN btrim(coalesce(p_row.import_batch_id, '')) = '' THEN 'missing_import_batch_id' END,
    CASE WHEN btrim(coalesce(p_row.community_source, '')) = '' THEN 'missing_community_source' END,
    CASE WHEN btrim(coalesce(p_row.venue_name, '')) = '' THEN 'missing_venue_name' END,
    CASE WHEN btrim(coalesce(p_row.address, '')) = '' THEN 'missing_address' END,
    CASE WHEN btrim(coalesce(p_row.city, '')) = '' THEN 'missing_city' END,
    CASE WHEN btrim(coalesce(p_row.state, '')) = '' THEN 'missing_state' END,
    CASE WHEN btrim(coalesce(p_row.zip_code, '')) = '' THEN 'missing_zip_code' END,
    CASE WHEN btrim(coalesce(p_row.country, '')) = '' THEN 'missing_country' END,
    CASE WHEN p_row.latitude IS NULL OR p_row.latitude < -90 OR p_row.latitude > 90 THEN 'invalid_latitude' END,
    CASE WHEN p_row.longitude IS NULL OR p_row.longitude < -180 OR p_row.longitude > 180 THEN 'invalid_longitude' END,
    CASE WHEN lower(btrim(coalesce(p_row.origin_type, ''))) <> 'community' THEN 'origin_type_must_be_community' END,
    CASE WHEN p_row.business_id IS NOT NULL THEN 'business_id_must_be_null' END,
    CASE WHEN p_row.owner_user_id IS NOT NULL THEN 'owner_user_id_must_be_null' END,
    CASE WHEN btrim(coalesce(p_row.owner_email, '')) <> '' THEN 'owner_email_must_be_blank' END,
    CASE WHEN lower(btrim(coalesce(p_row.admin_status, ''))) <> 'active' THEN 'admin_status_must_be_active' END,
    CASE WHEN btrim(coalesce(p_row.cover_photo_url, '')) <> '' THEN 'seeded_photos_not_allowed' END,
    CASE WHEN btrim(coalesce(p_row.menu_photo_url, '')) <> '' THEN 'seeded_photos_not_allowed' END,
    CASE WHEN btrim(coalesce(p_row.cover_photo_thumbnail_url, '')) <> '' THEN 'seeded_photos_not_allowed' END,
    CASE WHEN btrim(coalesce(p_row.menu_photo_thumbnail_url, '')) <> '' THEN 'seeded_photos_not_allowed' END,
    CASE WHEN btrim(coalesce(p_row.features, '')) <> '' THEN 'seeded_features_not_allowed' END,
    CASE
      WHEN btrim(coalesce(p_row.description, '')) <> ''
       AND NOT coalesce(p_row.description_is_basic_public_listing, false)
      THEN 'business_description_not_allowed'
    END,
    CASE
      WHEN length(btrim(coalesce(p_row.description, ''))) > 240
      THEN 'description_too_long_for_public_listing'
    END,
    CASE WHEN p_row.screen_count IS NOT NULL THEN 'seeded_screen_count_not_allowed' END,
    CASE WHEN p_row.serves_food IS NOT NULL THEN 'seeded_amenities_not_allowed' END,
    CASE WHEN p_row.has_wifi IS NOT NULL THEN 'seeded_amenities_not_allowed' END,
    CASE WHEN p_row.has_garden IS NOT NULL THEN 'seeded_amenities_not_allowed' END,
    CASE WHEN p_row.has_projector IS NOT NULL THEN 'seeded_amenities_not_allowed' END,
    CASE WHEN p_row.pet_friendly IS NOT NULL THEN 'seeded_amenities_not_allowed' END,
    CASE WHEN btrim(coalesce(p_row.supporter_country, '')) <> '' THEN 'supporter_country_not_allowed' END,
    CASE WHEN p_row.venue_identity_key IS NULL THEN 'missing_venue_identity_key' END
  ], NULL);
$$;

CREATE OR REPLACE FUNCTION public.community_venue_import_duplicate_candidates(
  p_import_batch_id text DEFAULT NULL
)
RETURNS TABLE (
  staging_id uuid,
  duplicate_kind text,
  duplicate_reason text,
  conflicting_id uuid,
  conflicting_name text
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH scoped AS (
    SELECT s.*
    FROM public.community_venue_import_staging s
    WHERE (p_import_batch_id IS NULL OR s.import_batch_id = p_import_batch_id)
      AND s.import_status NOT IN ('promoted', 'skipped')
  )
  SELECT
    s.id,
    'venue_identity_key'::text,
    'existing_venue_identity_key'::text,
    v.id,
    v.venue_name
  FROM scoped s
  JOIN public.venues v
    ON coalesce(v.venue_identity_key, public.gameon_venue_identity_key(v.venue_name, v.address, v.city, v.state, v.zip_code)) = s.venue_identity_key
  WHERE s.venue_identity_key IS NOT NULL
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'

  UNION ALL

  SELECT
    s.id,
    'normalized_name_address_city_state'::text,
    'existing_venue_normalized_location'::text,
    v.id,
    v.venue_name
  FROM scoped s
  JOIN public.venues v
    ON public.community_venue_import_normalize_venue_name(v.venue_name) = s.normalized_venue_name
   AND public.community_venue_import_normalize_address(v.address) = s.normalized_address
   AND public.gameon_normalize_venue_text(v.city) = s.normalized_city
   AND public.gameon_normalize_venue_state(v.state) = s.normalized_state
  WHERE s.normalized_venue_name IS NOT NULL
    AND s.normalized_address IS NOT NULL
    AND s.normalized_city IS NOT NULL
    AND s.normalized_state IS NOT NULL
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'

  UNION ALL

  SELECT
    s.id,
    'venue_identity_key'::text,
    'same_batch_identity_key'::text,
    other.id,
    other.venue_name
  FROM scoped s
  JOIN scoped other
    ON other.id <> s.id
   AND other.venue_identity_key = s.venue_identity_key
   AND (
     coalesce(other.source_row_number, 2147483647) < coalesce(s.source_row_number, 2147483647)
     OR (
       coalesce(other.source_row_number, 2147483647) = coalesce(s.source_row_number, 2147483647)
       AND other.id::text < s.id::text
     )
   )
  WHERE s.venue_identity_key IS NOT NULL

  UNION ALL

  SELECT
    s.id,
    'normalized_name_address_city_state'::text,
    'same_batch_normalized_location'::text,
    other.id,
    other.venue_name
  FROM scoped s
  JOIN scoped other
    ON other.id <> s.id
   AND other.normalized_venue_name = s.normalized_venue_name
   AND other.normalized_address = s.normalized_address
   AND other.normalized_city = s.normalized_city
   AND other.normalized_state = s.normalized_state
   AND (
     coalesce(other.source_row_number, 2147483647) < coalesce(s.source_row_number, 2147483647)
     OR (
       coalesce(other.source_row_number, 2147483647) = coalesce(s.source_row_number, 2147483647)
       AND other.id::text < s.id::text
     )
   )
  WHERE s.normalized_venue_name IS NOT NULL
    AND s.normalized_address IS NOT NULL
    AND s.normalized_city IS NOT NULL
    AND s.normalized_state IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.validate_community_venue_import_batch(
  p_import_batch_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_invalid integer := 0;
  v_duplicate integer := 0;
  v_ready integer := 0;
BEGIN
  IF btrim(coalesce(p_import_batch_id, '')) = '' THEN
    RAISE EXCEPTION 'import_batch_id is required'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.community_venue_import_staging s
  SET import_status = 'pending',
      duplicate_reason = NULL,
      updated_at = now()
  WHERE s.import_batch_id = p_import_batch_id
    AND s.import_status IN ('invalid', 'duplicate', 'ready');

  UPDATE public.community_venue_import_staging s
  SET import_status = 'invalid',
      duplicate_reason = array_to_string(public.community_venue_import_validation_errors(s), ';'),
      updated_at = now()
  WHERE s.import_batch_id = p_import_batch_id
    AND s.import_status = 'pending'
    AND cardinality(public.community_venue_import_validation_errors(s)) > 0;
  GET DIAGNOSTICS v_invalid = ROW_COUNT;

  WITH ranked AS (
    SELECT
      d.*,
      row_number() OVER (
        PARTITION BY d.staging_id
        ORDER BY
          CASE d.duplicate_reason
            WHEN 'existing_venue_identity_key' THEN 1
            WHEN 'existing_venue_normalized_location' THEN 2
            WHEN 'same_batch_identity_key' THEN 3
            ELSE 4
          END
      ) AS rn
    FROM public.community_venue_import_duplicate_candidates(p_import_batch_id) d
  )
  UPDATE public.community_venue_import_staging s
  SET import_status = 'duplicate',
      duplicate_reason = ranked.duplicate_reason,
      updated_at = now()
  FROM ranked
  WHERE ranked.rn = 1
    AND s.id = ranked.staging_id
    AND s.import_batch_id = p_import_batch_id
    AND s.import_status = 'pending';
  GET DIAGNOSTICS v_duplicate = ROW_COUNT;

  UPDATE public.community_venue_import_staging s
  SET import_status = 'ready',
      duplicate_reason = NULL,
      updated_at = now()
  WHERE s.import_batch_id = p_import_batch_id
    AND s.import_status = 'pending';
  GET DIAGNOSTICS v_ready = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'invalid', v_invalid,
    'duplicate', v_duplicate,
    'ready', v_ready
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.promote_community_venue_import_batch(
  p_import_batch_id text,
  p_curated_by text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_validation jsonb;
  v_blocking_rows integer := 0;
  v_inserted integer := 0;
BEGIN
  IF btrim(coalesce(p_import_batch_id, '')) = '' THEN
    RAISE EXCEPTION 'import_batch_id is required'
      USING ERRCODE = '22023';
  END IF;

  v_validation := public.validate_community_venue_import_batch(p_import_batch_id);

  SELECT count(*)
    INTO v_blocking_rows
  FROM public.community_venue_import_staging s
  WHERE s.import_batch_id = p_import_batch_id
    AND s.import_status IN ('invalid', 'duplicate');

  IF v_blocking_rows > 0 THEN
    RAISE EXCEPTION 'community_import_batch_not_ready'
      USING
        ERRCODE = 'P0001',
        DETAIL = format(
          'import_batch_id=%s has %s invalid/duplicate rows',
          p_import_batch_id,
          v_blocking_rows
        );
  END IF;

  WITH to_promote AS (
    SELECT *
    FROM public.community_venue_import_staging
    WHERE import_batch_id = p_import_batch_id
      AND import_status = 'ready'
  ),
  inserted AS (
    INSERT INTO public.venues (
      owner_email,
      business_id,
      owner_user_id,
      venue_name,
      address,
      address_line1,
      address_line2,
      city,
      state,
      zip_code,
      region,
      postal_code,
      country,
      formatted_address,
      phone,
      website,
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
      menu_photo_thumbnail_url,
      supporter_country,
      admin_status,
      origin_type,
      community_source,
      community_source_id,
      community_seed_batch,
      community_seeded_at,
      community_curated_by,
      community_provenance
    )
    SELECT
      NULL,
      NULL,
      NULL,
      btrim(s.venue_name),
      btrim(s.address),
      nullif(btrim(coalesce(s.address_line1, '')), ''),
      nullif(btrim(coalesce(s.address_line2, '')), ''),
      btrim(s.city),
      btrim(s.state),
      btrim(s.zip_code),
      nullif(btrim(coalesce(s.region, '')), ''),
      nullif(btrim(coalesce(s.postal_code, '')), ''),
      btrim(s.country),
      nullif(btrim(coalesce(s.formatted_address, '')), ''),
      nullif(btrim(coalesce(s.phone, '')), ''),
      nullif(btrim(coalesce(s.website, '')), ''),
      CASE
        WHEN s.description_is_basic_public_listing THEN nullif(btrim(coalesce(s.description, '')), '')
        ELSE ''
      END,
      '',
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      s.latitude,
      s.longitude,
      '',
      '',
      NULL,
      NULL,
      NULL,
      'active',
      'community',
      btrim(s.community_source),
      nullif(btrim(coalesce(s.community_source_id, '')), ''),
      btrim(s.import_batch_id),
      coalesce(s.community_seeded_at, now()),
      nullif(btrim(coalesce(p_curated_by, s.community_curated_by, '')), ''),
      coalesce(s.community_provenance, '{}'::jsonb)
        || jsonb_strip_nulls(jsonb_build_object(
          'public_email', nullif(btrim(coalesce(s.public_email, '')), ''),
          'source_row_number', s.source_row_number
        ))
    FROM to_promote s
    RETURNING id, venue_identity_key, community_source, community_source_id, community_seed_batch
  )
  UPDATE public.community_venue_import_staging s
  SET import_status = 'promoted',
      promoted_venue_id = inserted.id,
      promoted_at = now(),
      updated_at = now()
  FROM inserted
  WHERE s.import_batch_id = p_import_batch_id
    AND s.import_status = 'ready'
    AND s.venue_identity_key = inserted.venue_identity_key
    AND s.community_source = inserted.community_source
    AND s.import_batch_id = inserted.community_seed_batch
    AND s.community_source_id IS NOT DISTINCT FROM inserted.community_source_id;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'validation', v_validation,
    'promoted', v_inserted
  );
END;
$$;

ALTER TABLE public.community_venue_import_staging ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS community_venue_import_staging_no_client_select
  ON public.community_venue_import_staging;

CREATE POLICY community_venue_import_staging_no_client_select
  ON public.community_venue_import_staging
  FOR SELECT
  TO anon, authenticated
  USING (false);

REVOKE ALL ON public.community_venue_import_staging FROM PUBLIC;
REVOKE ALL ON FUNCTION public.community_venue_import_duplicate_candidates(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_community_venue_import_batch(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.promote_community_venue_import_batch(text, text) FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.community_venue_import_staging TO service_role;
GRANT EXECUTE ON FUNCTION public.community_venue_import_duplicate_candidates(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.validate_community_venue_import_batch(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.promote_community_venue_import_batch(text, text) TO service_role;
