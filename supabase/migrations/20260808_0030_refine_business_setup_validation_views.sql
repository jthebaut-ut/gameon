-- Refine business setup validation so community/seed businesses are not reported
-- as broken real business accounts.

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
WHERE (
  b.owner_user_id IS NOT NULL
  OR (
    coalesce(lower(btrim(b.owner_email)), '') <> ''
    AND lower(btrim(b.owner_email)) NOT LIKE '%@example.test'
    AND lower(btrim(b.owner_email)) NOT LIKE 'seed%@%'
    AND lower(btrim(b.owner_email)) NOT LIKE 'community%@%'
    AND lower(btrim(b.owner_email)) NOT LIKE '%+seed@%'
    AND lower(btrim(b.owner_email)) NOT LIKE '%+community@%'
  )
)
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
WHERE (
  b.owner_user_id IS NOT NULL
  OR (
    coalesce(lower(btrim(b.owner_email)), '') <> ''
    AND lower(btrim(b.owner_email)) NOT LIKE '%@example.test'
    AND lower(btrim(b.owner_email)) NOT LIKE 'seed%@%'
    AND lower(btrim(b.owner_email)) NOT LIKE 'community%@%'
    AND lower(btrim(b.owner_email)) NOT LIKE '%+seed@%'
    AND lower(btrim(b.owner_email)) NOT LIKE '%+community@%'
  )
)
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status
HAVING count(DISTINCT v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0
AND count(DISTINCT vc.id) FILTER (
  WHERE vc.id IS NOT NULL
    AND coalesce(lower(btrim(vc.approval_status)), '') NOT IN ('approved', 'rejected', 'cancelled', 'canceled')
) = 0;

CREATE OR REPLACE VIEW public.community_seed_businesses_without_owned_venues AS
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
WHERE b.owner_user_id IS NULL
  AND (
    coalesce(lower(btrim(b.owner_email)), '') = ''
    OR lower(btrim(b.owner_email)) LIKE '%@example.test'
    OR lower(btrim(b.owner_email)) LIKE 'seed%@%'
    OR lower(btrim(b.owner_email)) LIKE 'community%@%'
    OR lower(btrim(b.owner_email)) LIKE '%+seed@%'
    OR lower(btrim(b.owner_email)) LIKE '%+community@%'
  )
GROUP BY b.id, b.display_name, b.owner_email, b.owner_user_id, b.admin_status
HAVING count(v.id) FILTER (
  WHERE v.id IS NOT NULL
    AND coalesce(lower(btrim(v.admin_status)), 'active') IN ('active', 'plan_locked')
) = 0;

COMMENT ON VIEW public.businesses_with_zero_owned_venues IS
  'Validation: real owned business accounts with zero active/plan_locked owned venues; excludes seed/community placeholder businesses.';
COMMENT ON VIEW public.businesses_with_zero_approved_venues_and_zero_pending_claims IS
  'Validation: real owned business accounts with zero approved venues and zero pending/open claims; excludes seed/community placeholder businesses.';
COMMENT ON VIEW public.community_seed_businesses_without_owned_venues IS
  'Validation: seed/community placeholder businesses without active/plan_locked owned venues, separated from real business setup validation.';

NOTIFY pgrst, 'reload schema';
