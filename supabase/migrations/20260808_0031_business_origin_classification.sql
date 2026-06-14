-- Classify business rows by origin so real owner accounts and community seed
-- businesses can coexist without confusing admin/setup validation.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS business_origin text;

UPDATE public.businesses
SET business_origin = CASE
  WHEN owner_user_id IS NOT NULL THEN 'owned_account'
  WHEN lower(btrim(coalesce(owner_email, ''))) LIKE '%@example.test'
    OR lower(btrim(coalesce(owner_email, ''))) LIKE 'seed.%'
    OR lower(btrim(coalesce(owner_email, ''))) LIKE 'seed%@%'
    OR lower(btrim(coalesce(owner_email, ''))) LIKE 'community%@%'
    OR lower(btrim(coalesce(owner_email, ''))) LIKE '%+seed@%'
    OR lower(btrim(coalesce(owner_email, ''))) LIKE '%+community@%'
    THEN 'community_seed'
  ELSE 'owned_account'
END
WHERE business_origin IS NULL
  OR business_origin NOT IN ('owned_account', 'community_seed', 'claimed_community');

ALTER TABLE public.businesses
  ALTER COLUMN business_origin SET DEFAULT 'owned_account';

ALTER TABLE public.businesses
  ALTER COLUMN business_origin SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.businesses'::regclass
      AND conname = 'businesses_business_origin_check'
  ) THEN
    ALTER TABLE public.businesses
      ADD CONSTRAINT businesses_business_origin_check
      CHECK (business_origin IN ('owned_account', 'community_seed', 'claimed_community'));
  END IF;
END $$;

COMMENT ON COLUMN public.businesses.business_origin IS
  'Classifies business rows: owned_account for real business logins, community_seed for generated/community records, claimed_community when a community business is later claimed.';

DROP VIEW IF EXISTS public.businesses_with_zero_owned_venues;
DROP VIEW IF EXISTS public.businesses_with_zero_approved_venues_and_zero_pending_claims;
DROP VIEW IF EXISTS public.community_seed_businesses_without_owned_venues;
DROP VIEW IF EXISTS public.account_identity_conflicting_user_business_emails;
DROP VIEW IF EXISTS public.account_identity_auth_user_with_fan_and_business;
DROP VIEW IF EXISTS public.account_identity_duplicate_business_owner_emails;

CREATE VIEW public.account_identity_conflicting_user_business_emails AS
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
  AND b.business_origin IN ('owned_account', 'claimed_community')
GROUP BY lower(btrim(up.email));

CREATE VIEW public.account_identity_auth_user_with_fan_and_business AS
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
  AND b.business_origin IN ('owned_account', 'claimed_community')
GROUP BY up.id, lower(btrim(up.email));

CREATE VIEW public.account_identity_duplicate_business_owner_emails AS
SELECT
  lower(btrim(owner_email)) AS normalized_owner_email,
  count(*) AS business_count,
  array_agg(id ORDER BY created_at) AS business_ids,
  array_agg(DISTINCT owner_user_id) FILTER (WHERE owner_user_id IS NOT NULL) AS owner_user_ids
FROM public.businesses
WHERE coalesce(lower(btrim(owner_email)), '') <> ''
  AND coalesce(lower(btrim(admin_status)), 'active') IN ('active', 'archived', 'disabled')
  AND business_origin IN ('owned_account', 'claimed_community')
GROUP BY lower(btrim(owner_email))
HAVING count(*) > 1;

CREATE VIEW public.businesses_with_zero_owned_venues AS
SELECT
  b.id AS business_id,
  b.display_name,
  lower(btrim(coalesce(b.owner_email, ''))) AS normalized_owner_email,
  b.owner_user_id,
  b.admin_status,
  b.business_origin,
  count(v.id) FILTER (
    WHERE v.id IS NOT NULL
      AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
  ) AS owned_venue_count
FROM public.businesses b
LEFT JOIN public.venues v
  ON v.business_id = b.id
WHERE b.business_origin IN ('owned_account', 'claimed_community')
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status, b.business_origin
HAVING count(v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0;

CREATE VIEW public.businesses_with_zero_approved_venues_and_zero_pending_claims AS
SELECT
  b.id AS business_id,
  b.display_name,
  lower(btrim(coalesce(b.owner_email, ''))) AS normalized_owner_email,
  b.owner_user_id,
  b.admin_status,
  b.business_origin,
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
WHERE b.business_origin IN ('owned_account', 'claimed_community')
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status, b.business_origin
HAVING count(DISTINCT v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0
AND count(DISTINCT vc.id) FILTER (
  WHERE vc.id IS NOT NULL
    AND coalesce(lower(btrim(vc.approval_status)), '') NOT IN ('approved', 'rejected', 'cancelled', 'canceled')
) = 0;

CREATE VIEW public.community_seed_businesses_without_owned_venues AS
SELECT
  b.id AS business_id,
  b.display_name,
  lower(btrim(coalesce(b.owner_email, ''))) AS normalized_owner_email,
  b.owner_user_id,
  b.admin_status,
  b.business_origin,
  count(v.id) FILTER (
    WHERE v.id IS NOT NULL
      AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
  ) AS owned_venue_count
FROM public.businesses b
LEFT JOIN public.venues v
  ON v.business_id = b.id
WHERE b.business_origin = 'community_seed'
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status, b.business_origin
HAVING count(v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0;

COMMENT ON VIEW public.businesses_with_zero_owned_venues IS
  'Validation: login-owned businesses (owned_account or claimed_community) with zero active/plan_locked owned venues.';
COMMENT ON VIEW public.businesses_with_zero_approved_venues_and_zero_pending_claims IS
  'Validation: login-owned businesses (owned_account or claimed_community) with zero approved venues and zero pending/open claims.';
COMMENT ON VIEW public.community_seed_businesses_without_owned_venues IS
  'Validation: community_seed businesses without active/plan_locked owned venues, separated from real business setup validation.';
COMMENT ON VIEW public.account_identity_conflicting_user_business_emails IS
  'Validation: normalized email appearing in both user_profiles and login-owned businesses.';
COMMENT ON VIEW public.account_identity_auth_user_with_fan_and_business IS
  'Validation: same auth user acting as both fan profile and login-owned business owner.';
COMMENT ON VIEW public.account_identity_duplicate_business_owner_emails IS
  'Validation: duplicate normalized owner_email values among login-owned businesses.';

NOTIFY pgrst, 'reload schema';
