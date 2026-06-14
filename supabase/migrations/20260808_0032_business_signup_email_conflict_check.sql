-- Preflight check for business email/password signup.
--
-- Supabase Auth may return a non-error signup response for an existing email to avoid
-- account enumeration. The app needs a narrow server-side check so it can preserve
-- Fan vs Business separation and avoid showing a verification screen for an email
-- that cannot receive a new business signup verification.

CREATE OR REPLACE FUNCTION public.business_signup_email_conflict(p_email text)
RETURNS TABLE (
  conflict_type text,
  account_type text,
  auth_provider text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_account_type text;
  v_auth_provider text;
  v_auth_providers jsonb;
BEGIN
  IF v_email = '' THEN
    RETURN QUERY SELECT 'invalid_email'::text, NULL::text, NULL::text;
    RETURN;
  END IF;

  SELECT ai.account_type
  INTO v_account_type
  FROM public.account_identities ai
  WHERE ai.email = v_email
  LIMIT 1;

  IF v_account_type = 'fan' THEN
    RETURN QUERY SELECT 'fan_account'::text, 'fan'::text, NULL::text;
    RETURN;
  ELSIF v_account_type = 'business' THEN
    RETURN QUERY SELECT 'business_account'::text, 'business'::text, NULL::text;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE lower(btrim(coalesce(up.email, ''))) = v_email
      AND coalesce(lower(btrim(up.admin_status)), 'active') = 'active'
  ) THEN
    RETURN QUERY SELECT 'fan_account'::text, 'fan'::text, NULL::text;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE lower(btrim(coalesce(b.owner_email, ''))) = v_email
      AND coalesce(lower(btrim(b.admin_status)), 'active') IN ('active', 'archived', 'disabled')
      AND coalesce(lower(btrim(b.business_origin)), 'owned_account') IN ('owned_account', 'claimed_community')
  ) THEN
    RETURN QUERY SELECT 'business_account'::text, 'business'::text, NULL::text;
    RETURN;
  END IF;

  SELECT
    lower(coalesce(u.raw_app_meta_data ->> 'provider', '')),
    coalesce(u.raw_app_meta_data -> 'providers', '[]'::jsonb)
  INTO v_auth_provider, v_auth_providers
  FROM auth.users u
  WHERE lower(btrim(coalesce(u.email, ''))) = v_email
  LIMIT 1;

  IF FOUND THEN
    IF v_auth_provider = 'apple' OR coalesce(v_auth_providers, '[]'::jsonb) ? 'apple' THEN
      RETURN QUERY SELECT 'apple_auth'::text, NULL::text, 'apple'::text;
      RETURN;
    END IF;

    RETURN QUERY SELECT 'existing_auth'::text, NULL::text, NULLIF(v_auth_provider, '');
    RETURN;
  END IF;

  RETURN QUERY SELECT 'none'::text, NULL::text, NULL::text;
END;
$$;

REVOKE ALL ON FUNCTION public.business_signup_email_conflict(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.business_signup_email_conflict(text) TO anon, authenticated;
