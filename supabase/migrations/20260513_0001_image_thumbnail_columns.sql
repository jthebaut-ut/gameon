-- Optional thumbnail URLs for faster list/card loads (full URLs remain source of truth).
-- App falls back to full-size URLs when thumbnails are null or missing.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS avatar_thumbnail_url text;

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS cover_photo_thumbnail_url text,
  ADD COLUMN IF NOT EXISTS menu_photo_thumbnail_url text;

-- If `get_dm_inbox_summaries` is maintained in SQL, extend its SELECT to expose
-- `friend_avatar_thumbnail_url` from `user_profiles.avatar_thumbnail_url` so DM inbox rows can decode it.
