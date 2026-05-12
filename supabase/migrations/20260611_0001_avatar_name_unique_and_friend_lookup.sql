-- Case-insensitive unique avatar/display names (user_profiles.display_name) via avatar_name_normalized,
-- plus friend requests by normalized email or avatar name (lookup RPC).

-- ---------------------------------------------------------------------------
-- 1) Normalized display name column + backfill + dedupe existing collisions
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS avatar_name_normalized text;

-- Resolve duplicate display names (case-insensitive) before unique index: keep one row per
-- normalized name (lowest id), append disambiguator to the rest.
WITH ranked AS (
  SELECT
    id,
    display_name,
    row_number() OVER (
      PARTITION BY lower(trim(coalesce(display_name, '')))
      ORDER BY id
    ) AS rn
  FROM public.user_profiles
  WHERE nullif(trim(coalesce(display_name, '')), '') IS NOT NULL
)
UPDATE public.user_profiles u
SET display_name = left(
  r.display_name || ' #' || replace(r.id::text, '-', ''),
  200
)
FROM ranked r
WHERE u.id = r.id
  AND r.rn > 1;

UPDATE public.user_profiles
SET avatar_name_normalized = NULLIF(lower(trim(coalesce(display_name, ''))), '');

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_profiles_avatar_name_normalized
  ON public.user_profiles (avatar_name_normalized)
  WHERE avatar_name_normalized IS NOT NULL AND avatar_name_normalized <> '';

-- Keep normalized display_name in sync on insert/update (client may omit this column).
CREATE OR REPLACE FUNCTION public.user_profiles_set_avatar_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.avatar_name_normalized := NULLIF(lower(trim(coalesce(NEW.display_name, ''))), '');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_avatar_name_normalized ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_avatar_name_normalized
  BEFORE INSERT OR UPDATE OF display_name ON public.user_profiles
  FOR EACH ROW
  EXECUTE PROCEDURE public.user_profiles_set_avatar_name_normalized();

COMMENT ON COLUMN public.user_profiles.avatar_name_normalized IS
  'lower(trim(display_name)) when non-empty; enforced unique among active rows via partial unique index.';

-- ---------------------------------------------------------------------------
-- 2) Friend request by email OR avatar name (replaces send_friend_request_by_email)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.send_friend_request_by_email(text);

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

  -- 1) Email match first, then 2) avatar/display name (normalized).
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

COMMENT ON FUNCTION public.send_friend_request_by_lookup(text) IS
  'Authenticated caller sends a pending friend request: match active user by normalized email first, else by avatar_name_normalized.';
