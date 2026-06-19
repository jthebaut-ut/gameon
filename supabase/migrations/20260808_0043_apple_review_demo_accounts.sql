-- Permanent Apple App Store review demo accounts (idempotent).
--
-- Fan:     userdemo@userdemo.com / demo1234
-- Business: businessdemo@businessdemo.com / demo1234
--
-- Re-running this migration updates passwords, confirms emails, and reconciles profile/business rows.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Stable ids so re-runs target the same rows when created by this migration.
-- If auth users already exist under these emails with different ids, those existing ids win.
DO $$
DECLARE
  v_fan_email constant text := 'userdemo@userdemo.com';
  v_biz_email constant text := 'businessdemo@businessdemo.com';
  v_password constant text := 'demo1234';

  v_fan_seed_id constant uuid := 'a0000001-0001-4001-8001-000000000001'::uuid;
  v_biz_seed_id constant uuid := 'a0000002-0002-4002-8002-000000000002'::uuid;
  v_business_seed_id constant uuid := 'a0000003-0003-4003-8003-000000000003'::uuid;

  v_fan_user_id uuid;
  v_biz_user_id uuid;
  v_business_id uuid;
  v_now timestamptz := now();
  v_encrypted_pw text;
BEGIN
  v_encrypted_pw := crypt(v_password, gen_salt('bf'));

  -- -------------------------------------------------------------------------
  -- Fan auth user
  -- -------------------------------------------------------------------------
  SELECT id
    INTO v_fan_user_id
  FROM auth.users
  WHERE lower(btrim(email)) = v_fan_email
  LIMIT 1;

  IF v_fan_user_id IS NULL THEN
    v_fan_user_id := v_fan_seed_id;
    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      invited_at,
      confirmation_token,
      confirmation_sent_at,
      recovery_token,
      recovery_sent_at,
      email_change_token_new,
      email_change,
      email_change_sent_at,
      last_sign_in_at,
      raw_app_meta_data,
      raw_user_meta_data,
      is_super_admin,
      created_at,
      updated_at,
      phone,
      phone_change,
      phone_change_token,
      phone_change_sent_at,
      email_change_token_current,
      email_change_confirm_status,
      banned_until,
      reauthentication_token,
      reauthentication_sent_at,
      is_sso_user,
      deleted_at,
      is_anonymous
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_fan_user_id,
      'authenticated',
      'authenticated',
      v_fan_email,
      v_encrypted_pw,
      v_now,
      v_now,
      '',
      v_now,
      '',
      v_now,
      '',
      '',
      v_now,
      v_now,
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object(
        'email_verified', true,
        'display_name', 'FanGeo Demo User',
        'handle', 'userdemo',
        'bio', 'Sports fan demo account for App Store review.'
      ),
      false,
      v_now,
      v_now,
      null,
      '',
      '',
      v_now,
      '',
      0,
      null,
      '',
      v_now,
      false,
      null,
      false
    );
  ELSE
    UPDATE auth.users
    SET
      email = v_fan_email,
      encrypted_password = v_encrypted_pw,
      email_confirmed_at = coalesce(email_confirmed_at, v_now),
      updated_at = v_now,
      raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
        || jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object(
          'email_verified', true,
          'display_name', 'FanGeo Demo User',
          'handle', 'userdemo',
          'bio', 'Sports fan demo account for App Store review.'
        )
    WHERE id = v_fan_user_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM auth.identities
    WHERE user_id = v_fan_user_id
      AND provider = 'email'
  ) THEN
    INSERT INTO auth.identities (
      provider_id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at,
      id
    ) VALUES (
      v_fan_user_id::text,
      v_fan_user_id,
      jsonb_build_object(
        'sub', v_fan_user_id::text,
        'email', v_fan_email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      v_now,
      v_now,
      v_now,
      v_fan_user_id
    );
  ELSE
    UPDATE auth.identities
    SET
      provider_id = v_fan_user_id::text,
      identity_data = jsonb_build_object(
        'sub', v_fan_user_id::text,
        'email', v_fan_email,
        'email_verified', true,
        'phone_verified', false
      ),
      updated_at = v_now
    WHERE user_id = v_fan_user_id
      AND provider = 'email';
  END IF;

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_fan_user_id, v_fan_email, 'fan')
  ON CONFLICT (account_id) DO UPDATE
  SET
    email = excluded.email,
    account_type = excluded.account_type,
    updated_at = v_now;

  INSERT INTO public.user_profiles (
    id,
    email,
    display_name,
    username,
    handle,
    bio,
    avatar_url,
    avatar_thumbnail_url,
    is_business_account,
    admin_status,
    live_visibility_enabled,
    live_visibility_mode,
    selected_live_visibility_friend_ids,
    discoverable_by_fans,
    is_deleted
  ) VALUES (
    v_fan_user_id,
    v_fan_email,
    'FanGeo Demo User',
    'userdemo',
    'userdemo',
    'Sports fan demo account for App Store review.',
    '',
    null,
    false,
    'active',
    true,
    'all_friends',
    '{}'::uuid[],
    true,
    false
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = excluded.email,
    display_name = excluded.display_name,
    username = excluded.username,
    handle = excluded.handle,
    bio = excluded.bio,
    is_business_account = false,
    admin_status = 'active',
    live_visibility_enabled = excluded.live_visibility_enabled,
    live_visibility_mode = excluded.live_visibility_mode,
    selected_live_visibility_friend_ids = excluded.selected_live_visibility_friend_ids,
    discoverable_by_fans = excluded.discoverable_by_fans,
    is_deleted = false;

  -- -------------------------------------------------------------------------
  -- Business auth user
  -- -------------------------------------------------------------------------
  SELECT id
    INTO v_biz_user_id
  FROM auth.users
  WHERE lower(btrim(email)) = v_biz_email
  LIMIT 1;

  IF v_biz_user_id IS NULL THEN
    v_biz_user_id := v_biz_seed_id;
    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      invited_at,
      confirmation_token,
      confirmation_sent_at,
      recovery_token,
      recovery_sent_at,
      email_change_token_new,
      email_change,
      email_change_sent_at,
      last_sign_in_at,
      raw_app_meta_data,
      raw_user_meta_data,
      is_super_admin,
      created_at,
      updated_at,
      phone,
      phone_change,
      phone_change_token,
      phone_change_sent_at,
      email_change_token_current,
      email_change_confirm_status,
      banned_until,
      reauthentication_token,
      reauthentication_sent_at,
      is_sso_user,
      deleted_at,
      is_anonymous
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_biz_user_id,
      'authenticated',
      'authenticated',
      v_biz_email,
      v_encrypted_pw,
      v_now,
      v_now,
      '',
      v_now,
      '',
      v_now,
      '',
      '',
      v_now,
      v_now,
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object(
        'email_verified', true,
        'display_name', 'FanGeo Demo Business',
        'handle', 'businessdemo',
        'bio', 'Business demo account for App Store review.'
      ),
      false,
      v_now,
      v_now,
      null,
      '',
      '',
      v_now,
      '',
      0,
      null,
      '',
      v_now,
      false,
      null,
      false
    );
  ELSE
    UPDATE auth.users
    SET
      email = v_biz_email,
      encrypted_password = v_encrypted_pw,
      email_confirmed_at = coalesce(email_confirmed_at, v_now),
      updated_at = v_now,
      raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
        || jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object(
          'email_verified', true,
          'display_name', 'FanGeo Demo Business',
          'handle', 'businessdemo',
          'bio', 'Business demo account for App Store review.'
        )
    WHERE id = v_biz_user_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM auth.identities
    WHERE user_id = v_biz_user_id
      AND provider = 'email'
  ) THEN
    INSERT INTO auth.identities (
      provider_id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at,
      id
    ) VALUES (
      v_biz_user_id::text,
      v_biz_user_id,
      jsonb_build_object(
        'sub', v_biz_user_id::text,
        'email', v_biz_email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      v_now,
      v_now,
      v_now,
      v_biz_user_id
    );
  ELSE
    UPDATE auth.identities
    SET
      provider_id = v_biz_user_id::text,
      identity_data = jsonb_build_object(
        'sub', v_biz_user_id::text,
        'email', v_biz_email,
        'email_verified', true,
        'phone_verified', false
      ),
      updated_at = v_now
    WHERE user_id = v_biz_user_id
      AND provider = 'email';
  END IF;

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_biz_user_id, v_biz_email, 'business')
  ON CONFLICT (account_id) DO UPDATE
  SET
    email = excluded.email,
    account_type = excluded.account_type,
    updated_at = v_now;

  -- Business-only accounts must not also have an active fan profile on the same email.
  DELETE FROM public.user_profiles up
  WHERE lower(btrim(up.email)) = v_biz_email
    AND up.id IS DISTINCT FROM v_biz_user_id;

  DELETE FROM public.user_profiles up
  WHERE up.id = v_biz_user_id;

  SELECT b.id
    INTO v_business_id
  FROM public.businesses b
  WHERE b.owner_user_id = v_biz_user_id
     OR lower(btrim(coalesce(b.owner_email, ''))) = v_biz_email
  ORDER BY b.created_at NULLS LAST
  LIMIT 1;

  IF v_business_id IS NULL THEN
    v_business_id := v_business_seed_id;
    INSERT INTO public.businesses (
      id,
      display_name,
      owner_email,
      owner_user_id,
      admin_status,
      business_origin,
      plan_type,
      plan_status,
      pro_expires_at,
      venue_limit,
      monthly_host_limit,
      statistics_enabled,
      sponsored_enabled,
      unlimited_venues,
      unlimited_hosting,
      entitlement_updated_at
    ) VALUES (
      v_business_id,
      'FanGeo Sports Bar Demo',
      v_biz_email,
      v_biz_user_id,
      'active',
      'owned_account',
      'manual_pro',
      'active',
      null,
      999999,
      999999,
      true,
      true,
      true,
      true,
      v_now
    );
  ELSE
    UPDATE public.businesses
    SET
      display_name = 'FanGeo Sports Bar Demo',
      owner_email = v_biz_email,
      owner_user_id = v_biz_user_id,
      admin_status = 'active',
      business_origin = 'owned_account',
      plan_type = 'manual_pro',
      plan_status = 'active',
      pro_expires_at = null,
      venue_limit = 999999,
      monthly_host_limit = 999999,
      statistics_enabled = true,
      sponsored_enabled = true,
      unlimited_venues = true,
      unlimited_hosting = true,
      entitlement_updated_at = v_now,
      updated_at = v_now
    WHERE id = v_business_id;
  END IF;

  RAISE NOTICE '[AppleReviewDemo] fan_user_id=% business_user_id=% business_id=%',
    v_fan_user_id, v_biz_user_id, v_business_id;
END $$;

-- Read-only verification view for admin / post-migration checks.
CREATE OR REPLACE VIEW public.apple_review_demo_accounts_verification AS
WITH fan_auth AS (
  SELECT
    u.id,
    lower(btrim(u.email)) AS email,
    u.email_confirmed_at IS NOT NULL AS email_confirmed,
    u.encrypted_password IS NOT NULL AS has_password
  FROM auth.users u
  WHERE lower(btrim(u.email)) = 'userdemo@userdemo.com'
),
biz_auth AS (
  SELECT
    u.id,
    lower(btrim(u.email)) AS email,
    u.email_confirmed_at IS NOT NULL AS email_confirmed,
    u.encrypted_password IS NOT NULL AS has_password
  FROM auth.users u
  WHERE lower(btrim(u.email)) = 'businessdemo@businessdemo.com'
),
fan_profile AS (
  SELECT
    up.id,
    up.display_name,
    public.fangeo_normalize_handle(coalesce(up.handle, up.username)) AS handle,
    up.bio,
    coalesce(up.is_business_account, false) AS is_business_account,
    coalesce(up.admin_status, 'active') AS admin_status,
    coalesce(up.is_deleted, false) AS is_deleted
  FROM public.user_profiles up
  JOIN fan_auth fa ON fa.id = up.id
),
biz_business AS (
  SELECT
    b.id,
    b.display_name,
    b.owner_email,
    b.owner_user_id,
    b.admin_status,
    b.business_origin,
    b.plan_type,
    b.plan_status,
    coalesce(b.unlimited_venues, false) AS unlimited_venues,
    coalesce(b.unlimited_hosting, false) AS unlimited_hosting,
    coalesce(b.statistics_enabled, false) AS statistics_enabled,
    coalesce(b.sponsored_enabled, false) AS sponsored_enabled,
    (
      coalesce(b.plan_status, 'active') = 'active'
      AND coalesce(b.plan_type, 'free') IN ('pro_promo', 'pro_paid', 'manual_pro')
      AND (b.pro_expires_at IS NULL OR b.pro_expires_at > now())
    ) AS is_pro_active
  FROM public.businesses b
  JOIN biz_auth ba ON ba.id = b.owner_user_id
  WHERE coalesce(lower(btrim(b.admin_status)), 'active') = 'active'
)
SELECT
  'fan_auth_user_exists' AS check_name,
  EXISTS (SELECT 1 FROM fan_auth) AS passed,
  (SELECT id::text FROM fan_auth LIMIT 1) AS detail
UNION ALL
SELECT
  'fan_email_confirmed',
  coalesce((SELECT email_confirmed FROM fan_auth LIMIT 1), false),
  (SELECT email FROM fan_auth LIMIT 1)
UNION ALL
SELECT
  'fan_profile_exists',
  EXISTS (SELECT 1 FROM fan_profile),
  (SELECT display_name FROM fan_profile LIMIT 1)
UNION ALL
SELECT
  'fan_handle_userdemo',
  coalesce((SELECT handle = 'userdemo' FROM fan_profile LIMIT 1), false),
  (SELECT handle FROM fan_profile LIMIT 1)
UNION ALL
SELECT
  'fan_account_identity',
  EXISTS (
    SELECT 1
    FROM public.account_identities ai
    JOIN fan_auth fa ON fa.id = ai.account_id
    WHERE ai.account_type = 'fan'
  ),
  'fan'
UNION ALL
SELECT
  'business_auth_user_exists',
  EXISTS (SELECT 1 FROM biz_auth),
  (SELECT id::text FROM biz_auth LIMIT 1)
UNION ALL
SELECT
  'business_email_confirmed',
  coalesce((SELECT email_confirmed FROM biz_auth LIMIT 1), false),
  (SELECT email FROM biz_auth LIMIT 1)
UNION ALL
SELECT
  'business_row_exists',
  EXISTS (SELECT 1 FROM biz_business),
  (SELECT display_name FROM biz_business LIMIT 1)
UNION ALL
SELECT
  'business_manual_pro_active',
  coalesce((SELECT is_pro_active FROM biz_business LIMIT 1), false),
  (SELECT plan_type || '/' || plan_status FROM biz_business LIMIT 1)
UNION ALL
SELECT
  'business_pro_entitlements',
  coalesce((
    SELECT unlimited_venues
      AND unlimited_hosting
      AND statistics_enabled
      AND sponsored_enabled
    FROM biz_business
    LIMIT 1
  ), false),
  (SELECT
    'venues=' || unlimited_venues::text
    || ',hosting=' || unlimited_hosting::text
    || ',stats=' || statistics_enabled::text
    || ',sponsored=' || sponsored_enabled::text
   FROM biz_business
   LIMIT 1)
UNION ALL
SELECT
  'business_account_identity',
  EXISTS (
    SELECT 1
    FROM public.account_identities ai
    JOIN biz_auth ba ON ba.id = ai.account_id
    WHERE ai.account_type = 'business'
  ),
  'business'
UNION ALL
SELECT
  'no_email_conflict_fan_business',
  NOT EXISTS (
    SELECT 1
    FROM public.account_identity_conflicting_user_business_emails c
    WHERE c.normalized_email IN ('userdemo@userdemo.com', 'businessdemo@businessdemo.com')
  ),
  'account_identity_conflicting_user_business_emails';

COMMENT ON VIEW public.apple_review_demo_accounts_verification IS
  'Post-migration checks for permanent Apple review demo accounts. Query after applying 20260808_0043.';

REVOKE ALL ON public.apple_review_demo_accounts_verification FROM PUBLIC;
GRANT SELECT ON public.apple_review_demo_accounts_verification TO service_role;

NOTIFY pgrst, 'reload schema';
