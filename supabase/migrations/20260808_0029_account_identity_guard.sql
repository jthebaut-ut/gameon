-- Strict account-type ownership guard.
--
-- This migration is intentionally additive:
-- - Existing user_profiles / businesses rows are not backfilled into the guard table.
-- - Validation views below expose legacy conflicts so production data can be reviewed before
--   any hard backfill.
-- - New authenticated app flows should call claim_account_type(...) before creating/using
--   fan or business surfaces.

CREATE TABLE IF NOT EXISTS public.account_identities (
  account_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  account_type text NOT NULL CHECK (account_type IN ('fan', 'business')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id),
  CONSTRAINT account_identities_email_unique UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS idx_account_identities_account_type
  ON public.account_identities(account_type);

ALTER TABLE public.account_identities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS account_identities_select_own ON public.account_identities;
CREATE POLICY account_identities_select_own
  ON public.account_identities
  FOR SELECT
  TO authenticated
  USING (account_id = auth.uid());

CREATE OR REPLACE FUNCTION public.account_identity_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_account_identities_touch_updated_at ON public.account_identities;
CREATE TRIGGER trg_account_identities_touch_updated_at
  BEFORE UPDATE ON public.account_identities
  FOR EACH ROW
  EXECUTE FUNCTION public.account_identity_touch_updated_at();

CREATE OR REPLACE FUNCTION public.get_account_type_for_current_user()
RETURNS TABLE(account_type text, email text, account_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT ai.account_type, ai.email, ai.account_id
  FROM public.account_identities ai
  WHERE ai.account_id = auth.uid()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.claim_account_type(p_account_type text)
RETURNS TABLE(account_type text, email text, account_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_account_id uuid := auth.uid();
  v_email text;
  v_existing_by_email public.account_identities%ROWTYPE;
  v_existing_by_account public.account_identities%ROWTYPE;
  v_provider text;
  v_providers jsonb;
  v_is_apple boolean := false;
  v_email_verified boolean := false;
BEGIN
  p_account_type := lower(btrim(coalesce(p_account_type, '')));
  IF p_account_type NOT IN ('fan', 'business') THEN
    RAISE EXCEPTION 'Invalid account type.' USING ERRCODE = '22023';
  END IF;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to continue.' USING ERRCODE = '28000';
  END IF;

  SELECT
    lower(btrim(coalesce(u.email, ''))),
    u.raw_app_meta_data ->> 'provider',
    u.raw_app_meta_data -> 'providers',
    (
      u.email_confirmed_at IS NOT NULL
      OR lower(coalesce(u.raw_app_meta_data ->> 'provider', '')) = 'apple'
      OR coalesce(u.raw_app_meta_data -> 'providers', '[]'::jsonb) ? 'apple'
    )
  INTO v_email, v_provider, v_providers, v_email_verified
  FROM auth.users u
  WHERE u.id = v_account_id;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'A verified email address is required.' USING ERRCODE = '28000';
  END IF;

  v_is_apple := lower(coalesce(v_provider, '')) = 'apple'
    OR coalesce(v_providers, '[]'::jsonb) ? 'apple';

  IF NOT v_email_verified AND NOT v_is_apple THEN
    RAISE EXCEPTION 'Please verify your email before continuing.' USING ERRCODE = '28000';
  END IF;

  SELECT *
  INTO v_existing_by_email
  FROM public.account_identities ai
  WHERE ai.email = v_email
  LIMIT 1;

  IF FOUND THEN
    IF v_existing_by_email.account_id = v_account_id
       AND v_existing_by_email.account_type = p_account_type THEN
      RETURN QUERY
      SELECT v_existing_by_email.account_type, v_existing_by_email.email, v_existing_by_email.account_id;
      RETURN;
    END IF;

    IF v_existing_by_email.account_type = 'fan' THEN
      RAISE EXCEPTION 'Email already used for a Fan account.' USING ERRCODE = '23505';
    ELSE
      RAISE EXCEPTION 'Email already used for a Business account.' USING ERRCODE = '23505';
    END IF;
  END IF;

  SELECT *
  INTO v_existing_by_account
  FROM public.account_identities ai
  WHERE ai.account_id = v_account_id
  LIMIT 1;

  IF FOUND THEN
    IF v_existing_by_account.account_type = p_account_type THEN
      UPDATE public.account_identities ai
      SET email = v_email
      WHERE ai.account_id = v_account_id
      RETURNING ai.account_type, ai.email, ai.account_id
      INTO account_type, email, account_id;
      RETURN NEXT;
      RETURN;
    END IF;

    IF v_existing_by_account.account_type = 'fan' THEN
      RAISE EXCEPTION 'This auth user is already claimed as a Fan account.' USING ERRCODE = '23505';
    ELSE
      RAISE EXCEPTION 'This auth user is already claimed as a Business account.' USING ERRCODE = '23505';
    END IF;
  END IF;

  INSERT INTO public.account_identities(account_id, email, account_type)
  VALUES (v_account_id, v_email, p_account_type)
  RETURNING account_identities.account_type, account_identities.email, account_identities.account_id
  INTO account_type, email, account_id;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.get_account_type_for_current_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_type_for_current_user() TO authenticated;

REVOKE ALL ON FUNCTION public.claim_account_type(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_account_type(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_fan_account_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_email text;
  v_row_email text := lower(btrim(coalesce(NEW.email, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Fan profile auth user mismatch.' USING ERRCODE = '42501';
  END IF;

  SELECT lower(btrim(coalesce(email, '')))
  INTO v_auth_email
  FROM auth.users
  WHERE id = auth.uid();

  IF v_row_email <> v_auth_email THEN
    RAISE EXCEPTION 'Fan profile email must match the authenticated user email.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.claim_account_type('fan');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_account_identity_guard ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_account_identity_guard
  BEFORE INSERT OR UPDATE OF id, email ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_fan_account_identity_guard();

CREATE OR REPLACE FUNCTION public.enforce_business_account_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_email text;
  v_owner_email text := lower(btrim(coalesce(NEW.owner_email, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.owner_user_id IS NOT NULL AND NEW.owner_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Business owner auth user mismatch.' USING ERRCODE = '42501';
  END IF;

  SELECT lower(btrim(coalesce(email, '')))
  INTO v_auth_email
  FROM auth.users
  WHERE id = auth.uid();

  IF v_owner_email <> '' AND v_owner_email <> v_auth_email THEN
    RAISE EXCEPTION 'Business owner email must match the authenticated user email.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.claim_account_type('business');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_account_identity_guard ON public.businesses;
CREATE TRIGGER trg_businesses_account_identity_guard
  BEFORE INSERT OR UPDATE OF owner_user_id, owner_email ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_business_account_identity_guard();

-- Validation views for existing data review before any hard backfill.

CREATE OR REPLACE VIEW public.account_identity_conflicting_user_business_emails AS
SELECT
  lower(btrim(up.email)) AS normalized_email,
  array_agg(DISTINCT up.id) AS fan_user_ids,
  array_agg(DISTINCT b.id) AS business_ids,
  array_agg(DISTINCT b.owner_user_id) FILTER (WHERE b.owner_user_id IS NOT NULL) AS business_owner_user_ids
FROM public.user_profiles up
JOIN public.businesses b
  ON lower(btrim(up.email)) = lower(btrim(b.owner_email))
WHERE coalesce(lower(btrim(up.email)), '') <> ''
  AND coalesce(lower(btrim(up.admin_status)), 'active') = 'active'
  AND coalesce(lower(btrim(b.admin_status)), 'active') IN ('active', 'archived', 'disabled')
GROUP BY lower(btrim(up.email));

CREATE OR REPLACE VIEW public.account_identity_auth_user_with_fan_and_business AS
SELECT
  up.id AS account_id,
  lower(btrim(up.email)) AS fan_email,
  array_agg(DISTINCT b.id) AS business_ids,
  array_agg(DISTINCT lower(btrim(b.owner_email))) AS business_emails
FROM public.user_profiles up
JOIN public.businesses b
  ON b.owner_user_id = up.id
WHERE coalesce(lower(btrim(up.admin_status)), 'active') = 'active'
  AND coalesce(lower(btrim(b.admin_status)), 'active') IN ('active', 'archived', 'disabled')
GROUP BY up.id, lower(btrim(up.email));

CREATE OR REPLACE VIEW public.account_identity_duplicate_business_owner_emails AS
SELECT
  lower(btrim(owner_email)) AS normalized_owner_email,
  count(*) AS business_count,
  array_agg(id ORDER BY created_at) AS business_ids,
  array_agg(DISTINCT owner_user_id) FILTER (WHERE owner_user_id IS NOT NULL) AS owner_user_ids
FROM public.businesses
WHERE coalesce(lower(btrim(owner_email)), '') <> ''
  AND coalesce(lower(btrim(admin_status)), 'active') IN ('active', 'archived', 'disabled')
GROUP BY lower(btrim(owner_email))
HAVING count(*) > 1;

CREATE OR REPLACE VIEW public.businesses_with_zero_owned_venues AS
SELECT
  b.id AS business_id,
  b.display_name,
  lower(btrim(coalesce(b.owner_email, ''))) AS normalized_owner_email,
  b.owner_user_id,
  b.admin_status,
  count(v.id) FILTER (
    WHERE v.id IS NOT NULL
      AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
  ) AS owned_venue_count
FROM public.businesses b
LEFT JOIN public.venues v
  ON v.business_id = b.id
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status
HAVING count(v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0;

CREATE OR REPLACE VIEW public.businesses_with_zero_approved_venues_and_zero_pending_claims AS
SELECT
  b.id AS business_id,
  b.display_name,
  lower(btrim(coalesce(b.owner_email, ''))) AS normalized_owner_email,
  b.owner_user_id,
  b.admin_status,
  count(DISTINCT v.id) FILTER (
    WHERE v.id IS NOT NULL
      AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
  ) AS approved_venue_count,
  count(DISTINCT vc.id) FILTER (
    WHERE vc.id IS NOT NULL
      AND coalesce(lower(btrim(vc.approval_status)), '') NOT IN ('approved', 'rejected', 'cancelled', 'canceled')
  ) AS pending_claim_count
FROM public.businesses b
LEFT JOIN public.venues v
  ON v.business_id = b.id
LEFT JOIN public.venue_claims vc
  ON vc.business_id = b.id
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status
HAVING count(DISTINCT v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0
AND count(DISTINCT vc.id) FILTER (
  WHERE vc.id IS NOT NULL
    AND coalesce(lower(btrim(vc.approval_status)), '') NOT IN ('approved', 'rejected', 'cancelled', 'canceled')
) = 0;

COMMENT ON VIEW public.account_identity_conflicting_user_business_emails IS
  'Validation: normalized email appearing in both user_profiles and businesses.';
COMMENT ON VIEW public.account_identity_auth_user_with_fan_and_business IS
  'Validation: same auth user acting as both fan profile and business owner.';
COMMENT ON VIEW public.account_identity_duplicate_business_owner_emails IS
  'Validation: duplicate normalized owner_email values in businesses.';
COMMENT ON VIEW public.businesses_with_zero_owned_venues IS
  'Validation: businesses with zero active/plan_locked owned venues.';
COMMENT ON VIEW public.businesses_with_zero_approved_venues_and_zero_pending_claims IS
  'Validation: businesses with zero approved venues and zero pending/open claims.';

NOTIFY pgrst, 'reload schema';
