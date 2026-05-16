-- Public @handle (username) for fan profiles: nullable for legacy rows, unique when set.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS username text;

UPDATE public.user_profiles
SET username = NULL
WHERE username IS NOT NULL AND trim(username) = '';

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_profiles_username_lower
  ON public.user_profiles (
    lower(
      trim(
        regexp_replace(
          coalesce(username, ''),
          '^@+',
          ''
        )
      )
    )
  )
  WHERE username IS NOT NULL AND trim(username) <> '';

ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_username_format_check;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_username_format_check
  CHECK (
    username IS NULL
    OR (
      char_length(trim(username)) >= 3
      AND char_length(trim(username)) <= 20
      AND trim(username) ~ '^[a-zA-Z0-9_.]+$'
    )
  );

-- Scalar availability check (mirrors display_name RPC pattern).
CREATE OR REPLACE FUNCTION public.check_username_available(
  p_username text,
  p_exclude_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN p_exclude_user_id IS NOT NULL AND p_exclude_user_id IS DISTINCT FROM auth.uid() THEN false
    WHEN nullif(
      lower(
        trim(
          regexp_replace(
            coalesce(p_username, ''),
            '^@+',
            ''
          )
        )
      ),
      ''
    ) IS NULL THEN false
    WHEN char_length(
      nullif(
        lower(
          trim(
            regexp_replace(
              coalesce(p_username, ''),
              '^@+',
              ''
            )
          )
        ),
        ''
      )
    ) < 3 THEN false
    WHEN char_length(
      nullif(
        lower(
          trim(
            regexp_replace(
              coalesce(p_username, ''),
              '^@+',
              ''
            )
          )
        ),
        ''
      )
    ) > 20 THEN false
    WHEN nullif(
      lower(
        trim(
          regexp_replace(
            coalesce(p_username, ''),
            '^@+',
            ''
          )
        )
      ),
      ''
    ) !~ '^[a-z0-9_.]+$' THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
        AND up.username IS NOT NULL
        AND lower(
          trim(
            regexp_replace(
              coalesce(up.username, ''),
              '^@+',
              ''
            )
          )
        ) = lower(
          trim(
            regexp_replace(
              coalesce(p_username, ''),
              '^@+',
              ''
            )
          )
        )
        AND up.id IS DISTINCT FROM COALESCE(p_exclude_user_id, auth.uid())
    )
  END;
$$;

REVOKE ALL ON FUNCTION public.check_username_available(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_username_available(text, uuid) TO authenticated;

COMMENT ON FUNCTION public.check_username_available(text, uuid) IS
  'True if normalized @handle is free among active profiles; false for invalid input or anonymous caller.';

-- Friend lookup: @handle first, then email, then display name fields.
CREATE OR REPLACE FUNCTION public.send_friend_request_by_lookup(p_query text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  n text;
  n_handle text;
  target uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  n := lower(trim(coalesce(p_query, '')));
  IF n = '' THEN
    RAISE EXCEPTION 'Enter a @handle, name, or email.';
  END IF;

  n_handle := trim(regexp_replace(n, '^@+', ''));

  SELECT up.id INTO target
  FROM public.user_profiles up
  WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND COALESCE(up.is_business_account, false) = false
    AND up.username IS NOT NULL
    AND lower(
      trim(
        regexp_replace(
          coalesce(up.username, ''),
          '^@+',
          ''
        )
      )
    ) = n_handle
  ORDER BY up.created_at ASC NULLS LAST
  LIMIT 1;

  IF target IS NULL AND n_handle <> n THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND up.username IS NOT NULL
      AND lower(
        trim(
          regexp_replace(
            coalesce(up.username, ''),
            '^@+',
            ''
          )
        )
      ) = n
    ORDER BY up.created_at ASC NULLS LAST
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND lower(trim(coalesce(up.email, ''))) = n
    ORDER BY up.created_at ASC NULLS LAST
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND up.display_name_normalized IS NOT NULL
      AND up.display_name_normalized = n
    ORDER BY up.created_at ASC NULLS LAST
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND lower(trim(coalesce(up.display_name, ''))) = n
    ORDER BY up.created_at ASC NULLS LAST
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    RAISE EXCEPTION 'No FanGeo account found with that @handle, name, or email.';
  END IF;

  PERFORM public.friendship_ensure_pending(target);
END;
$$;

REVOKE ALL ON FUNCTION public.send_friend_request_by_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request_by_lookup(text) TO authenticated;

COMMENT ON FUNCTION public.send_friend_request_by_lookup(text) IS
  'Friend lookup: active non-business user_profiles (@handle, email, display_name_normalized, display_name); then friendship_ensure_pending.';
