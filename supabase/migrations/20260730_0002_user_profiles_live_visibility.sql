-- Privacy control for identity-based Live friend presence.
-- Public aggregate attendance/crowd counts continue to come from venue_event_interests.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS live_visibility_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_profiles.live_visibility_enabled IS
  'When false, hide this user from Live friend presence, friends-going indicators, and avatar stacks while preserving aggregate attendance counts.';
