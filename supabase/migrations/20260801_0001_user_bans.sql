-- FanGio admin user bans.
-- Additive only: creates ban records, indexes, service-role RLS, and an RPC
-- that app clients can later call to inspect their own active ban.

CREATE TABLE IF NOT EXISTS public.user_bans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  user_email text,
  admin_email text NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) > 0),
  starts_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  lifted_at timestamptz,
  lifted_by text,
  lift_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_bans_time_window_check
    CHECK (expires_at IS NULL OR expires_at > starts_at),
  CONSTRAINT user_bans_lift_reason_check
    CHECK (lifted_at IS NULL OR lifted_by IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_user_bans_user_id_created_at
  ON public.user_bans (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_bans_user_id_active
  ON public.user_bans (user_id, expires_at)
  WHERE lifted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_user_bans_expires_at
  ON public.user_bans (expires_at)
  WHERE expires_at IS NOT NULL AND lifted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_user_bans_lifted_at
  ON public.user_bans (lifted_at DESC)
  WHERE lifted_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_bans_admin_email_created_at
  ON public.user_bans (admin_email, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_bans_user_email_created_at
  ON public.user_bans (lower(user_email), created_at DESC)
  WHERE user_email IS NOT NULL;

CREATE OR REPLACE FUNCTION public.user_bans_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_bans_touch_updated_at ON public.user_bans;
CREATE TRIGGER user_bans_touch_updated_at
  BEFORE UPDATE ON public.user_bans
  FOR EACH ROW
  EXECUTE FUNCTION public.user_bans_touch_updated_at();

CREATE OR REPLACE FUNCTION public.is_user_ban_active(
  p_expires_at timestamptz,
  p_lifted_at timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_lifted_at IS NULL
     AND (p_expires_at IS NULL OR p_expires_at > now());
$$;

CREATE OR REPLACE FUNCTION public.get_my_active_ban()
RETURNS TABLE (
  id uuid,
  user_id uuid,
  reason text,
  starts_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    ub.id,
    ub.user_id,
    ub.reason,
    ub.starts_at,
    ub.expires_at,
    ub.created_at
  FROM public.user_bans ub
  WHERE ub.user_id = auth.uid()
    AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
  ORDER BY ub.created_at DESC
  LIMIT 1;
END;
$$;

ALTER TABLE public.user_bans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role can manage user bans"
  ON public.user_bans;

CREATE POLICY "Service role can manage user bans"
  ON public.user_bans
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

REVOKE ALL ON public.user_bans FROM anon;
REVOKE ALL ON public.user_bans FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_bans TO service_role;

REVOKE ALL ON FUNCTION public.get_my_active_ban() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_active_ban() TO authenticated;

REVOKE ALL ON FUNCTION public.is_user_ban_active(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_user_ban_active(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_ban_active(timestamptz, timestamptz) TO service_role;

COMMENT ON TABLE public.user_bans IS
  'Admin-created temporary and permanent user bans. Service-role writes only; clients use get_my_active_ban().';

COMMENT ON FUNCTION public.get_my_active_ban() IS
  'Returns the current authenticated user''s newest active ban, if one exists.';
