-- Outgoing pending cancel: soft status = cancelled (RLS-safe via RPC), revive on re-send,
-- and extend friendship_ensure_pending to reuse cancelled rows.

-- ---------------------------------------------------------------------------
-- 1) Requester cancels own pending request → cancelled (hidden from both sides’ lists)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_outgoing_friend_request(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  n int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  UPDATE public.friendships f
  SET
    status = 'cancelled',
    responded_at = now()
  WHERE f.id = p_id
    AND f.requester_id = me
    AND f.status = 'pending';

  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'Friend request not found or cannot be cancelled.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_outgoing_friend_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_outgoing_friend_request(uuid) TO authenticated;

COMMENT ON FUNCTION public.cancel_outgoing_friend_request(uuid) IS
  'Authenticated requester sets their own pending friend request to cancelled (soft remove for both parties).';

-- ---------------------------------------------------------------------------
-- 2) friendship_ensure_pending: revive same-direction cancelled row before INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.friendship_ensure_pending(p_addressee uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  fid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_addressee IS NULL OR p_addressee = me THEN
    RAISE EXCEPTION 'You cannot add yourself.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = me AND b.blocked_user_id = p_addressee)
       OR (b.blocker_user_id = p_addressee AND b.blocked_user_id = me)
  ) THEN
    RAISE EXCEPTION 'You can''t send a friend request to this user.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status IN ('pending', 'accepted')
      AND (
        (f.requester_id = me AND f.addressee_id = p_addressee)
        OR (f.requester_id = p_addressee AND f.addressee_id = me)
      )
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  SELECT f.id INTO fid
  FROM public.friendships f
  WHERE f.requester_id = me
    AND f.addressee_id = p_addressee
    AND f.status = 'declined'
    AND f.addressee_cleared_at IS NOT NULL
  LIMIT 1;

  IF fid IS NOT NULL THEN
    UPDATE public.friendships
    SET
      status = 'pending',
      responded_at = NULL,
      addressee_cleared_at = NULL,
      requester_cleared_at = NULL
    WHERE id = fid;
    RETURN fid;
  END IF;

  SELECT f.id INTO fid
  FROM public.friendships f
  WHERE f.requester_id = me
    AND f.addressee_id = p_addressee
    AND f.status = 'cancelled'
  LIMIT 1;

  IF fid IS NOT NULL THEN
    UPDATE public.friendships
    SET
      status = 'pending',
      responded_at = NULL,
      addressee_cleared_at = NULL,
      requester_cleared_at = NULL
    WHERE id = fid;
    RETURN fid;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.requester_id = me
      AND f.addressee_id = p_addressee
      AND f.status = 'declined'
      AND f.addressee_cleared_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  INSERT INTO public.friendships (requester_id, addressee_id, status)
  VALUES (me, p_addressee, 'pending')
  RETURNING id INTO fid;

  RETURN fid;
END;
$$;

REVOKE ALL ON FUNCTION public.friendship_ensure_pending(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friendship_ensure_pending(uuid) TO authenticated;

COMMENT ON FUNCTION public.friendship_ensure_pending(uuid) IS
  'Send or revive pending friend request; supports revival from declined (after addressee clear) or cancelled.';
