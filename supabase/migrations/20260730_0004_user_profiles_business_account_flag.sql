-- Backfill schema dependency used by profile/friend lookup logic.
-- Existing code treats missing values as regular fan profiles.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS is_business_account boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_profiles.is_business_account IS
  'Marks synthetic/business identity rows; regular fan profiles default to false.';
