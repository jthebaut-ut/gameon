-- Venue identity key + duplicate protection for venue_claims and venues.
-- Normalization: lower, trim, collapse whitespace, strip non-alphanumeric (keep spaces), digits-only zip.
-- Does not delete or alter approval flow except blocking duplicate inserts/updates.

-- ---------------------------------------------------------------------------
-- Normalization helpers (IMMUTABLE for generated columns / indexes)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_normalize_venue_text(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          LOWER(COALESCE(input, '')),
          '\s+',
          ' ',
          'g'
        ),
        '[^a-z0-9 ]',
        '',
        'g'
      )
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_normalize_venue_state(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT lower(trim(COALESCE(input, '')));
$$;

CREATE OR REPLACE FUNCTION public.gameon_normalize_venue_zip(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NULLIF(
    regexp_replace(lower(trim(COALESCE(input, ''))), '[^0-9]', '', 'g'),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_venue_identity_key(
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
  SELECT md5(
    concat_ws(
      '|',
      public.gameon_normalize_venue_text(p_name),
      public.gameon_normalize_venue_text(p_address),
      public.gameon_normalize_venue_text(p_city),
      public.gameon_normalize_venue_state(p_state),
      COALESCE(public.gameon_normalize_venue_zip(p_zip), '')
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_venue_claim_is_open_pending(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NOT (
    lower(trim(COALESCE(p_status, ''))) = 'approved'
    OR lower(trim(COALESCE(p_status, ''))) LIKE '%reject%'
  );
$$;

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS venue_identity_key text;

COMMENT ON COLUMN public.venues.venue_identity_key IS
  'MD5 of normalized venue name + address + city + state + zip; used for duplicate detection.';

ALTER TABLE public.venue_claims
  ADD COLUMN IF NOT EXISTS venue_identity_key text;

COMMENT ON COLUMN public.venue_claims.venue_identity_key IS
  'MD5 of normalized location fields; duplicate checks and admin visibility.';

-- ---------------------------------------------------------------------------
-- BEFORE trigger: set venue_identity_key on venues
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_venues_set_venue_identity_key()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.venue_identity_key := public.gameon_venue_identity_key(
    NEW.venue_name,
    NEW.address,
    NEW.city,
    NEW.state,
    NEW.zip_code
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_venues_set_venue_identity_key ON public.venues;
CREATE TRIGGER trg_venues_set_venue_identity_key
  BEFORE INSERT OR UPDATE OF venue_name, address, city, state, zip_code
  ON public.venues
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_venues_set_venue_identity_key();

-- ---------------------------------------------------------------------------
-- Identity guard for venue_claims (set key + raise on duplicate)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_venue_claims_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
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
    NEW.venue_name,
    NEW.venue_address,
    NEW.venue_city,
    NEW.venue_state,
    NEW.venue_zip_code
  );
  NEW.venue_identity_key := k;

  -- Same business: active venue row
  SELECT EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.venue_identity_key = k
      AND v.admin_status = 'active'
      AND (
        (NEW.business_id IS NOT NULL AND v.business_id IS NOT DISTINCT FROM NEW.business_id)
        OR (
          NEW.business_id IS NULL
          AND v.business_id IS NULL
          AND lower(trim(COALESCE(v.owner_email, ''))) = lower(trim(COALESCE(NEW.owner_email, '')))
        )
      )
  )
  INTO same_biz_venue;

  -- Same business: another approved claim (same identity)
  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims c
    WHERE c.venue_identity_key = k
      AND (NEW.id IS NULL OR c.id <> NEW.id)
      AND lower(trim(COALESCE(c.approval_status, ''))) = 'approved'
      AND (c.business_id IS NOT DISTINCT FROM NEW.business_id)
      AND lower(trim(COALESCE(c.owner_email, ''))) = lower(trim(COALESCE(NEW.owner_email, '')))
  )
  INTO same_biz_approved_claim;

  IF same_biz_venue OR same_biz_approved_claim THEN
    RAISE EXCEPTION 'duplicate_venue_same_business'
      USING ERRCODE = 'P0001';
  END IF;

  -- Same business: another open (pending) claim
  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims c
    WHERE c.venue_identity_key = k
      AND (NEW.id IS NULL OR c.id <> NEW.id)
      AND public.gameon_venue_claim_is_open_pending(c.approval_status)
      AND (c.business_id IS NOT DISTINCT FROM NEW.business_id)
      AND lower(trim(COALESCE(c.owner_email, ''))) = lower(trim(COALESCE(NEW.owner_email, '')))
  )
  INTO same_biz_pending_claim;

  IF same_biz_pending_claim THEN
    RAISE EXCEPTION 'duplicate_claim_pending'
      USING ERRCODE = 'P0001';
  END IF;

  -- Another tenant: active venue or any open claim or approved claim
  SELECT EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.venue_identity_key = k
      AND v.admin_status = 'active'
      AND NOT (
        (NEW.business_id IS NOT NULL AND v.business_id IS NOT DISTINCT FROM NEW.business_id)
        OR (
          NEW.business_id IS NULL
          AND v.business_id IS NULL
          AND lower(trim(COALESCE(v.owner_email, ''))) = lower(trim(COALESCE(NEW.owner_email, '')))
        )
      )
  )
  INTO other_active_venue;

  SELECT EXISTS (
    SELECT 1
    FROM public.venue_claims c
    WHERE c.venue_identity_key = k
      AND (NEW.id IS NULL OR c.id <> NEW.id)
      AND (
        public.gameon_venue_claim_is_open_pending(c.approval_status)
        OR lower(trim(COALESCE(c.approval_status, ''))) = 'approved'
      )
      AND NOT (
        (c.business_id IS NOT DISTINCT FROM NEW.business_id)
        AND lower(trim(COALESCE(c.owner_email, ''))) = lower(trim(COALESCE(NEW.owner_email, '')))
      )
  )
  INTO other_open_claim;

  IF other_active_venue OR other_open_claim THEN
    RAISE EXCEPTION 'duplicate_venue_other_business'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_venue_claims_identity_guard ON public.venue_claims;
CREATE TRIGGER trg_venue_claims_identity_guard
  BEFORE INSERT OR UPDATE OF venue_name, venue_address, venue_city, venue_state, venue_zip_code, business_id, owner_email
  ON public.venue_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_venue_claims_identity_guard();

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------

UPDATE public.venues v
SET venue_identity_key = public.gameon_venue_identity_key(
  v.venue_name,
  v.address,
  v.city,
  v.state,
  v.zip_code
)
WHERE v.venue_identity_key IS NULL;

UPDATE public.venue_claims c
SET venue_identity_key = public.gameon_venue_identity_key(
  c.venue_name,
  c.venue_address,
  c.venue_city,
  c.venue_state,
  c.venue_zip_code
)
WHERE c.venue_identity_key IS NULL;

-- ---------------------------------------------------------------------------
-- Unique: one active venue per identity (global)
-- ---------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS idx_venues_unique_identity_active
  ON public.venues (venue_identity_key)
  WHERE admin_status = 'active'
    AND venue_identity_key IS NOT NULL;

-- One open (non-approved, non-rejected) claim per identity globally
CREATE UNIQUE INDEX IF NOT EXISTS idx_venue_claims_unique_open_identity
  ON public.venue_claims (venue_identity_key)
  WHERE venue_identity_key IS NOT NULL
    AND public.gameon_venue_claim_is_open_pending(approval_status);

-- ---------------------------------------------------------------------------
-- RPC: preflight duplicate check (SECURITY DEFINER — no row data returned)
-- ---------------------------------------------------------------------------

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
    FROM public.venues v
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
    FROM public.venue_claims c
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
    FROM public.venue_claims c
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
    FROM public.venues v
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
    FROM public.venue_claims c
    WHERE c.venue_identity_key = k
      AND c.id <> excl
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

REVOKE ALL ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_venue_claim_duplicate(uuid, text, text, text, text, text, text, uuid) TO service_role;
