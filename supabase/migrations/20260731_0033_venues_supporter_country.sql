-- Lightweight World Cup / tournament supporter mode for venues.
-- Stores one optional venue-supported country/team label for public venue game cards.

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS supporter_country text NULL;

COMMENT ON COLUMN public.venues.supporter_country IS
  'Optional venue-owned tournament supporter country/team label, e.g. Mexico, United States, France.';
