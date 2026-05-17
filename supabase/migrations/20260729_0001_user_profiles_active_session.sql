-- Single-device fan login: active session id on user_profiles.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS active_session_id text,
  ADD COLUMN IF NOT EXISTS active_session_updated_at timestamptz;

COMMENT ON COLUMN public.user_profiles.active_session_id IS
  'Latest fan app session instance UUID; other devices with a stale local id are signed out.';
COMMENT ON COLUMN public.user_profiles.active_session_updated_at IS
  'When active_session_id was last claimed by a fan device.';

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_profiles_select_own_active_session ON public.user_profiles;
CREATE POLICY user_profiles_select_own_active_session
  ON public.user_profiles FOR SELECT TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS user_profiles_update_own_active_session ON public.user_profiles;
CREATE POLICY user_profiles_update_own_active_session
  ON public.user_profiles FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'user_profiles'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_profiles;
  END IF;
END $$;
