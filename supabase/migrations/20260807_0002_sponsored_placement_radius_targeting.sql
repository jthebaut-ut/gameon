-- Add optional radius targeting metadata for sponsored placements.
-- Existing country/state/city/sport targeting and the iOS lookup RPC remain unchanged.

ALTER TABLE public.sponsored_placements
  ADD COLUMN IF NOT EXISTS target_lat double precision,
  ADD COLUMN IF NOT EXISTS target_lng double precision,
  ADD COLUMN IF NOT EXISTS target_radius_miles numeric;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'sponsored_placements_target_lat_range_check'
      AND conrelid = 'public.sponsored_placements'::regclass
  ) THEN
    ALTER TABLE public.sponsored_placements
      ADD CONSTRAINT sponsored_placements_target_lat_range_check
      CHECK (target_lat IS NULL OR (target_lat >= -90 AND target_lat <= 90));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'sponsored_placements_target_lng_range_check'
      AND conrelid = 'public.sponsored_placements'::regclass
  ) THEN
    ALTER TABLE public.sponsored_placements
      ADD CONSTRAINT sponsored_placements_target_lng_range_check
      CHECK (target_lng IS NULL OR (target_lng >= -180 AND target_lng <= 180));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'sponsored_placements_target_radius_positive_check'
      AND conrelid = 'public.sponsored_placements'::regclass
  ) THEN
    ALTER TABLE public.sponsored_placements
      ADD CONSTRAINT sponsored_placements_target_radius_positive_check
      CHECK (target_radius_miles IS NULL OR target_radius_miles > 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_sponsored_placements_radius_center
  ON public.sponsored_placements (target_lat, target_lng)
  WHERE target_lat IS NOT NULL AND target_lng IS NOT NULL;

COMMENT ON COLUMN public.sponsored_placements.target_lat IS
  'Optional latitude center for admin-configured regional sponsored placement targeting.';

COMMENT ON COLUMN public.sponsored_placements.target_lng IS
  'Optional longitude center for admin-configured regional sponsored placement targeting.';

COMMENT ON COLUMN public.sponsored_placements.target_radius_miles IS
  'Optional radius in miles for admin-configured regional sponsored placement targeting.';
