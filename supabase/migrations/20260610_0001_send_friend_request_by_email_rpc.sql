-- Add friend by email: resolve active user_profiles row by normalized email, enforce blocks and duplicate pending/accepted, insert pending friendship.
-- SECURITY DEFINER so lookup does not depend on SELECT RLS for other users' emails.

CREATE OR REPLACE FUNCTION public.send_friend_request_by_email(p_email text)
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

  n := lower(trim(coalesce(p_email, '')));
  IF n = '' THEN
    RAISE EXCEPTION 'Enter an email address.';
  END IF;

  SELECT up.id INTO target
  FROM public.user_profiles up
  WHERE lower(trim(coalesce(up.email, ''))) = n
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
  LIMIT 1;

  IF target IS NULL THEN
    RAISE EXCEPTION 'No FanGeo account found with that email.';
  END IF;

  IF target = me THEN
    RAISE EXCEPTION 'You can''t send a friend request to yourself.';
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
    RAISE EXCEPTION 'A friend request already exists with this person.';
  END IF;

  INSERT INTO public.friendships (requester_id, addressee_id, status)
  VALUES (me, target, 'pending');
END;
$$;

REVOKE ALL ON FUNCTION public.send_friend_request_by_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request_by_email(text) TO authenticated;

COMMENT ON FUNCTION public.send_friend_request_by_email(text) IS
  'Authenticated caller sends a pending friend request to the user whose user_profiles.email matches lower(trim(p_email)).';

-- Speed up email resolution (expression matches lookup predicate).
CREATE INDEX IF NOT EXISTS idx_user_profiles_email_normalized_lookup
  ON public.user_profiles (lower(trim(coalesce(email, ''))))
  WHERE coalesce(trim(email), '') <> '';
