-- Optional short bio for fan profiles.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS bio text;

ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_bio_length_check;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_bio_length_check
  CHECK (
    bio IS NULL
    OR char_length(bio) <= 160
  );

COMMENT ON COLUMN public.user_profiles.bio IS
  'Optional user-entered profile bio, limited to 160 characters.';
