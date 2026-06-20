-- Future FanGeo+ ad-free entitlement (no purchase flow yet; defaults off for all users).

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS ad_free_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_profiles.ad_free_enabled IS
  'When true, FanGeo hides AdMob placements for this user. Reserved for future FanGeo+ subscription; not exposed in app UI yet.';
