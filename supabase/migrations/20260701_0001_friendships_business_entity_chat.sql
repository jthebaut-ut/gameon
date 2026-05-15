-- Business chat targets use public.businesses.id (not owner_user_id, not fan user_profiles).
-- Smallest extension: entity type columns on friendships + user→business pending RPC.
-- Existing user↔user rows keep requester_entity_type/addressee_entity_type = 'user' (defaults).

ALTER TABLE public.friendships
  ADD COLUMN IF NOT EXISTS requester_entity_type text NOT NULL DEFAULT 'user',
  ADD COLUMN IF NOT EXISTS addressee_entity_type text NOT NULL DEFAULT 'user';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'friendships_requester_entity_type_check'
  ) THEN
    ALTER TABLE public.friendships
      ADD CONSTRAINT friendships_requester_entity_type_check
      CHECK (requester_entity_type IN ('user', 'business'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'friendships_addressee_entity_type_check'
  ) THEN
    ALTER TABLE public.friendships
      ADD CONSTRAINT friendships_addressee_entity_type_check
      CHECK (addressee_entity_type IN ('user', 'business'));
  END IF;
END $$;

COMMENT ON COLUMN public.friendships.requester_entity_type IS
  'user = requester_id is auth user / user_profiles.id; business = requester_id is businesses.id';
COMMENT ON COLUMN public.friendships.addressee_entity_type IS
  'user = addressee_id is auth user / user_profiles.id; business = addressee_id is businesses.id';

CREATE INDEX IF NOT EXISTS friendships_user_to_business_pending_idx
  ON public.friendships (requester_id, addressee_id)
  WHERE addressee_entity_type = 'business' AND status = 'pending';

CREATE INDEX IF NOT EXISTS friendships_business_addressee_idx
  ON public.friendships (addressee_id)
  WHERE addressee_entity_type = 'business';

-- Fan user sends a pending request to an active business (no owner_user_id required).
CREATE OR REPLACE FUNCTION public.friendship_ensure_pending_to_business(p_business_id uuid)
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

  IF p_business_id IS NULL OR p_business_id = me THEN
    RAISE EXCEPTION 'You cannot add yourself.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
  ) THEN
    RAISE EXCEPTION 'Business not found.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status IN ('pending', 'accepted')
      AND (
        (f.requester_id = me AND f.requester_entity_type = 'user'
          AND f.addressee_id = p_business_id AND f.addressee_entity_type = 'business')
        OR (f.requester_id = p_business_id AND f.requester_entity_type = 'business'
          AND f.addressee_id = me AND f.addressee_entity_type = 'user')
      )
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  SELECT f.id INTO fid
  FROM public.friendships f
  WHERE f.requester_id = me
    AND f.requester_entity_type = 'user'
    AND f.addressee_id = p_business_id
    AND f.addressee_entity_type = 'business'
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
    AND f.requester_entity_type = 'user'
    AND f.addressee_id = p_business_id
    AND f.addressee_entity_type = 'business'
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
      AND f.requester_entity_type = 'user'
      AND f.addressee_id = p_business_id
      AND f.addressee_entity_type = 'business'
      AND f.status = 'declined'
      AND f.addressee_cleared_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  INSERT INTO public.friendships (
    requester_id,
    addressee_id,
    status,
    requester_entity_type,
    addressee_entity_type
  )
  VALUES (me, p_business_id, 'pending', 'user', 'business')
  RETURNING id INTO fid;

  RETURN fid;
END;
$$;

REVOKE ALL ON FUNCTION public.friendship_ensure_pending_to_business(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friendship_ensure_pending_to_business(uuid) TO authenticated;

COMMENT ON FUNCTION public.friendship_ensure_pending_to_business(uuid) IS
  'Fan user (auth.uid) sends or revives pending friend request to public.businesses.id; does not use owner_user_id.';
