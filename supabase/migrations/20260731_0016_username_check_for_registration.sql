-- Allow @handle availability checks during fan signup before auth session exists.

CREATE OR REPLACE FUNCTION public.check_username_available_for_registration(p_username text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
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
    )
  END;
$$;

REVOKE ALL ON FUNCTION public.check_username_available_for_registration(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_username_available_for_registration(text) TO anon, authenticated;

COMMENT ON FUNCTION public.check_username_available_for_registration(text) IS
  'True if normalized @handle is free among active profiles; for pre-auth fan signup only.';
