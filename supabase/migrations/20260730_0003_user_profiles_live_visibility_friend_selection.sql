-- Friend-level Live privacy controls for identity-based public participation visibility.
-- Aggregate attendance/crowd counts remain unchanged.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS live_visibility_mode text NOT NULL DEFAULT 'all_friends',
  ADD COLUMN IF NOT EXISTS selected_live_visibility_friend_ids uuid[] NOT NULL DEFAULT '{}';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_live_visibility_mode_check'
      AND conrelid = 'public.user_profiles'::regclass
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_live_visibility_mode_check
      CHECK (live_visibility_mode IN ('all_friends', 'selected_friends'));
  END IF;
END
$$;

COMMENT ON COLUMN public.user_profiles.live_visibility_mode IS
  'Controls which friends can see this user in Live friend presence: all_friends or selected_friends.';

COMMENT ON COLUMN public.user_profiles.selected_live_visibility_friend_ids IS
  'When live_visibility_mode is selected_friends, only these accepted friend user IDs can see identity/avatar Live presence.';
