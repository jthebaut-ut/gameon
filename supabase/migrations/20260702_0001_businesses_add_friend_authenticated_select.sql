-- Add Friend: authenticated fans must read active businesses for owner_email / display_name search.
-- Does not change friendships or direct_messages.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'businesses'
      AND c.relrowsecurity = false
  ) THEN
    ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;
  END IF;
END $$;

DROP POLICY IF EXISTS businesses_select_active_authenticated_add_friend ON public.businesses;

CREATE POLICY businesses_select_active_authenticated_add_friend
  ON public.businesses
  FOR SELECT
  TO authenticated
  USING (lower(trim(coalesce(admin_status, ''))) = 'active');

COMMENT ON POLICY businesses_select_active_authenticated_add_friend ON public.businesses IS
  'Allows signed-in fans to discover active businesses in Add Friend search (display_name, owner_email).';
