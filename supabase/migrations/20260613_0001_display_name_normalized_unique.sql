-- Unique case-insensitive display names via generated display_name_normalized + RPC preflight.
-- Replaces avatar_name_normalized (same semantics, canonical column name).

-- ---------------------------------------------------------------------------
-- 1) Remove legacy avatar_name_normalized (trigger + index + column)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_user_profiles_avatar_name_normalized ON public.user_profiles;
DROP FUNCTION IF EXISTS public.user_profiles_set_avatar_name_normalized();
DROP INDEX IF EXISTS uq_user_profiles_avatar_name_normalized;
ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS avatar_name_normalized;

-- ---------------------------------------------------------------------------
-- 2) Dedupe existing display_name collisions before unique constraint
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3) Generated normalized column (always in sync with display_name)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_profiles'
      AND column_name = 'display_name_normalized'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD COLUMN display_name_normalized text
      GENERATED ALWAYS AS (
        NULLIF(lower(trim(coalesce(display_name, ''))), '')
      ) STORED;
  END IF;
END
$$;

COMMENT ON COLUMN public.user_profiles.display_name_normalized IS
  'lower(trim(display_name)) when non-empty; unique among all rows with a non-empty name.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_profiles_display_name_normalized
  ON public.user_profiles (display_name_normalized)
  WHERE display_name_normalized IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4) Preflight: true if normalized name is unused by another user (RLS-safe via SECURITY DEFINER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_display_name_normalized_available(p_display_name text)
RETURNS TABLE(available boolean)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN QUERY SELECT false;
    RETURN;
  END IF;
  RETURN QUERY
  SELECT (
    NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.display_name_normalized IS NOT NULL
        AND up.display_name_normalized = NULLIF(lower(trim(coalesce(p_display_name, ''))), '')
        AND up.id IS DISTINCT FROM auth.uid()
    )
  )::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.check_display_name_normalized_available(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_display_name_normalized_available(text) TO authenticated;

COMMENT ON FUNCTION public.check_display_name_normalized_available(text) IS
  'Returns one row {available}: true if no other user_profiles row has the same display_name_normalized (empty names always available).';

-- ---------------------------------------------------------------------------
-- 5) Friend lookup: use display_name_normalized instead of avatar_name_normalized
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

