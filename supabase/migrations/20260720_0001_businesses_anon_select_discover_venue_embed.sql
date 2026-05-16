-- Guest Discover embeds `businesses(owner_email, admin_status)` on `venues` selects.
-- Without an anon SELECT policy, RLS blocks nested reads and the client never receives
-- business-level owner_email for multi-venue locations.

DROP POLICY IF EXISTS businesses_select_active_anon_discover_venue_embed ON public.businesses;

CREATE POLICY businesses_select_active_anon_discover_venue_embed
  ON public.businesses
  FOR SELECT
  TO anon
  USING (lower(trim(coalesce(admin_status, ''))) = 'active');

COMMENT ON POLICY businesses_select_active_anon_discover_venue_embed ON public.businesses IS
  'Guest Discover: read active business rows for public venue listing contact (owner_email only via PostgREST embed).';

GRANT SELECT ON public.businesses TO anon;
