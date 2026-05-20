-- Community / unclaimed venues: amenity columns should be NULL (unverified), not false (unavailable).

UPDATE public.venues
SET
  screen_count = NULL,
  serves_food = NULL,
  has_wifi = NULL,
  has_garden = NULL,
  has_projector = NULL,
  pet_friendly = NULL
WHERE business_id IS NULL
  AND COALESCE(trim(owner_email), '') = '';

COMMENT ON COLUMN public.venues.serves_food IS
  'NULL = unverified (community seed). true/false = owner-confirmed when business_id is set.';
