-- Admin / debug: inspect venue listing email fields and linked business (run in Supabase SQL Editor as postgres or service_role).
-- Use after client logs show business_id / owner_email nil for a venue (e.g. name contains "Venue4").
--
-- Expected for a business-owned listing you want Email on Discover:
--   venues.business_id → active businesses.id, and/or venues.owner_email set to the public business contact
--   businesses.owner_email present when joining on business_id
--
-- 1) Find venue row(s) — adjust the predicate (exact name, ILIKE, or id).

SELECT
  v.id AS venues_id,
  v.venue_name AS venues_name,
  v.owner_email AS venues_owner_email,
  v.business_id AS venues_business_id,
  v.admin_status AS venues_admin_status,
  b.id AS businesses_id,
  b.display_name AS businesses_display_name,
  b.owner_email AS businesses_owner_email,
  b.admin_status AS businesses_admin_status
FROM public.venues v
LEFT JOIN public.businesses b ON b.id = v.business_id
WHERE v.venue_name ILIKE '%Venue4%'
ORDER BY v.venue_name, v.id;

-- 2) Optional: single venue by id (uncomment and set UUID)

-- SELECT
--   v.id,
--   v.venue_name,
--   v.owner_email,
--   v.business_id,
--   v.admin_status,
--   b.owner_email AS businesses_owner_email,
--   b.admin_status AS businesses_admin_status
-- FROM public.venues v
-- LEFT JOIN public.businesses b ON b.id = v.business_id
-- WHERE v.id = '00000000-0000-0000-0000-000000000000'::uuid;
