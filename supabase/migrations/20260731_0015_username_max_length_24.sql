-- Extend @handle max length from 20 to 24 (matches FanGeoHandleRules + signup UI).

ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_username_format_check;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_username_format_check
  CHECK (
    username IS NULL
    OR (
      char_length(trim(username)) >= 3
      AND char_length(trim(username)) <= 24
      AND trim(username) ~ '^[a-zA-Z0-9_.]+$'
    )
  );

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
    ) > 24 THEN false
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
