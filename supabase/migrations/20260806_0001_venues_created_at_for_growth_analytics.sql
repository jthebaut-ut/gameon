-- Add a stable creation timestamp for venue rows so Growth Analytics can
-- count and sort business-created venues by creation date.
--
-- This is additive only. Existing rows receive the migration application time
-- because no earlier venue creation timestamp exists in the current schema.

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_venues_created_at
  ON public.venues (created_at DESC);

COMMENT ON COLUMN public.venues.created_at IS
  'Creation timestamp for venue rows. Added for admin Growth Analytics and future operational reporting.';
