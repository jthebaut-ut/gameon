-- Add display_name (lower(trim)) fallback to send_friend_request_by_lookup after email and display_name_normalized.

CREATE OR REPLACE FUNCTION public.send_friend_request_by_lookup(p_query text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  n text;
  target uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  n := lower(trim(coalesce(p_query, '')));
  IF n = '' THEN
    RAISE EXCEPTION 'Enter an email or display name.';
  END IF;

  SELECT up.id INTO target
  FROM public.user_profiles up
  WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND lower(trim(coalesce(up.email, ''))) = n
  LIMIT 1;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.display_name_normalized IS NOT NULL
      AND up.display_name_normalized = n
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND lower(trim(coalesce(up.display_name, ''))) = n
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    RAISE EXCEPTION 'No FanGeo account found with that email or display name.';
  END IF;

  PERFORM public.friendship_ensure_pending(target);
END;
$$;

REVOKE ALL ON FUNCTION public.send_friend_request_by_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request_by_lookup(text) TO authenticated;

COMMENT ON FUNCTION public.send_friend_request_by_lookup(text) IS
  'Friend lookup: normalized email, then display_name_normalized, then lower(trim(display_name)); then friendship_ensure_pending.';
