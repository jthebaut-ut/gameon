-- Public rebrand copy: update friend lookup errors to FanGeo branding.

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
    RAISE EXCEPTION 'Enter an email or avatar name.';
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
    RAISE EXCEPTION 'No FanGeo account found with that email or avatar name.';
  END IF;

  IF target = me THEN
    RAISE EXCEPTION 'You cannot add yourself.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = me AND b.blocked_user_id = target)
       OR (b.blocker_user_id = target AND b.blocked_user_id = me)
  ) THEN
    RAISE EXCEPTION 'You can''t send a friend request to this user.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status IN ('pending', 'accepted')
      AND (
        (f.requester_id = me AND f.addressee_id = target)
        OR (f.requester_id = target AND f.addressee_id = me)
      )
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  INSERT INTO public.friendships (requester_id, addressee_id, status)
  VALUES (me, target, 'pending');
END;
$$;

REVOKE ALL ON FUNCTION public.send_friend_request_by_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request_by_lookup(text) TO authenticated;
