-- Link approved venue rows to the authenticated business owner (auth.users.id) for client queries and RLS parity.
ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS owner_user_id uuid NULL;

COMMENT ON COLUMN public.venues.owner_user_id IS
  'Optional auth user id of the venue/business owner; set on admin claim approval from public.businesses.owner_user_id when available.';

CREATE INDEX IF NOT EXISTS idx_venues_owner_user_id
  ON public.venues (owner_user_id)
  WHERE owner_user_id IS NOT NULL;
