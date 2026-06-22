-- Allow iOS clients to read active Discover banner announcements from admin dashboard.

DO $$
BEGIN
  IF to_regclass('public.announcements') IS NOT NULL THEN
    ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS announcements_discover_banner_public_read ON public.announcements;
    CREATE POLICY announcements_discover_banner_public_read
      ON public.announcements
      FOR SELECT
      TO anon, authenticated
      USING (
        display_type = 'discover_banner'
        AND status IN ('active', 'scheduled')
      );
  END IF;
END $$;
