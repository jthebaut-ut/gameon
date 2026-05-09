-- Venue photo-change review workflow (post-approval).
-- Stores pending photo URLs so public fields are not overwritten until admin approves.

alter table public.venues
  add column if not exists pending_cover_photo_url text,
  add column if not exists pending_menu_photo_url text,
  add column if not exists photo_review_status text not null default 'approved',
  add column if not exists photo_review_created_at timestamptz;

-- TODO: Add RLS policies + constraints so only owners can set pending_* and only admins/functions can approve.

