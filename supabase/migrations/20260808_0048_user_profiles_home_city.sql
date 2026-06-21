-- User-selected home city for fan profile identity (not GPS / device location).

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS home_city text,
  ADD COLUMN IF NOT EXISTS home_region text,
  ADD COLUMN IF NOT EXISTS home_country text,
  ADD COLUMN IF NOT EXISTS show_home_city boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_profiles.home_city IS
  'User-selected home city label for profile identity (optional, not device location).';
COMMENT ON COLUMN public.user_profiles.home_region IS
  'User-selected home region/state/province for profile identity display.';
COMMENT ON COLUMN public.user_profiles.home_country IS
  'User-selected home country for profile identity display.';
COMMENT ON COLUMN public.user_profiles.show_home_city IS
  'When true, home city is shown on the fan profile identity strip.';
