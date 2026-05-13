-- Friend requests: soft decline + per-side clear, RPCs for reliable updates under RLS,
-- Realtime publication for friendships, and lookup RPC aligned with revive rules.

-- ---------------------------------------------------------------------------
-- 1) Columns (receiver / requester soft-dismiss for declined rows)
-- ---------------------------------------------------------------------------
ALTER TABLE public.friendships
  ADD COLUMN IF NOT EXISTS addressee_cleared_at timestamptz,
  ADD COLUMN IF NOT EXISTS requester_cleared_at timestamptz;

COMMENT ON COLUMN public.friendships.addressee_cleared_at IS
  'When set, the addressee no longer sees this declined row in their incoming list.';
COMMENT ON COLUMN public.friendships.requester_cleared_at IS
  'When set, the requester no longer sees this declined row in their sent list.';

-- ---------------------------------------------------------------------------
-- 2) Supabase Realtime (postgres changes)
-- ---------------------------------------------------------------------------
DO $pub$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'friendships'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.friendships;
  END IF;
END
$pub$;

-- ---------------------------------------------------------------------------
-- 3) Core RPC: insert pending or revive a declined row after addressee cleared
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

  -- Same-direction declined row: revive only after addressee dismissed their declined copy.
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

  -- Declined but addressee has not cleared yet — treat as still active for this pair.
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
  'Authenticated user sends (or revives) a pending friend request to p_addressee; enforces blocks and duplicate pending/accepted.';

-- ---------------------------------------------------------------------------
-- 4) Decline (addressee only, pending → declined)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.decline_friend_request(p_id uuid)
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
    status = 'declined',
    responded_at = now()
  WHERE f.id = p_id
    AND f.addressee_id = me
    AND f.status = 'pending';

  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'Friend request not found or cannot be declined.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.decline_friend_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decline_friend_request(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Clear dismissed declined row (per side)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_friend_request_view(p_id uuid)
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
    addressee_cleared_at = CASE
      WHEN f.addressee_id = me AND f.status = 'declined' THEN now()
      ELSE f.addressee_cleared_at
    END,
    requester_cleared_at = CASE
      WHEN f.requester_id = me AND f.status = 'declined' THEN now()
      ELSE f.requester_cleared_at
    END
  WHERE f.id = p_id
    AND f.status = 'declined'
    AND (f.addressee_id = me OR f.requester_id = me);

  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'Friend request not found or cannot be cleared.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_friend_request_view(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clear_friend_request_view(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6) Lookup RPC: resolve target then delegate to friendship_ensure_pending
-- ---------------------------------------------------------------------------
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
      AND up.avatar_name_normalized IS NOT NULL
      AND up.avatar_name_normalized = n
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    RAISE EXCEPTION 'No FanGeo account found with that email or avatar name.';
  END IF;

  PERFORM public.friendship_ensure_pending(target);
END;
$$;

REVOKE ALL ON FUNCTION public.send_friend_request_by_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request_by_lookup(text) TO authenticated;
