-- Lightweight MVP user presence. The app writes a throttled heartbeat to
-- user_profiles.last_seen_at; online status is computed dynamically.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz NULL;

COMMENT ON COLUMN public.user_profiles.last_seen_at IS
  'Last lightweight app heartbeat for MVP presence. Online is computed as last_seen_at within a short window.';

CREATE INDEX IF NOT EXISTS idx_user_profiles_last_seen_at
  ON public.user_profiles (last_seen_at DESC)
  WHERE last_seen_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.touch_user_presence()
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := now();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  UPDATE public.user_profiles
  SET last_seen_at = v_now
  WHERE id = auth.uid();

  RETURN v_now;
END;
$$;

COMMENT ON FUNCTION public.touch_user_presence() IS
  'Updates only the authenticated user profile last_seen_at for lightweight app presence.';

REVOKE ALL ON FUNCTION public.touch_user_presence() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_user_presence() TO authenticated;

CREATE OR REPLACE FUNCTION public.get_live_operations_presence_metrics()
RETURNS TABLE (
  users_online_now integer,
  businesses_online_now integer,
  active_users_today integer,
  active_users_this_week integer,
  active_users_this_month integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    count(*) FILTER (
      WHERE coalesce(up.is_business_account, false) = false
        AND up.last_seen_at >= now() - interval '2 minutes'
    )::integer AS users_online_now,
    count(*) FILTER (
      WHERE coalesce(up.is_business_account, false) = true
        AND up.last_seen_at >= now() - interval '2 minutes'
    )::integer AS businesses_online_now,
    count(*) FILTER (
      WHERE up.last_seen_at >= now() - interval '1 day'
    )::integer AS active_users_today,
    count(*) FILTER (
      WHERE up.last_seen_at >= now() - interval '7 days'
    )::integer AS active_users_this_week,
    count(*) FILTER (
      WHERE up.last_seen_at >= now() - interval '30 days'
    )::integer AS active_users_this_month
  FROM public.user_profiles up
  WHERE coalesce(lower(btrim(up.admin_status)), 'active') = 'active'
    AND coalesce(up.is_deleted, false) = false;
$$;

COMMENT ON FUNCTION public.get_live_operations_presence_metrics() IS
  'Aggregated MVP live operations presence metrics derived from user_profiles.last_seen_at.';

REVOKE ALL ON FUNCTION public.get_live_operations_presence_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_live_operations_presence_metrics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_operations_presence_metrics() TO service_role;
