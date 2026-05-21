-- FanGeo handles: public unique identity.
-- Display names are intentionally non-unique; handle/username stays unique
-- case-insensitively and is normalized without a leading @.

CREATE OR REPLACE FUNCTION public.fangeo_normalize_handle(p_handle text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
    lower(
      trim(
        regexp_replace(coalesce(p_handle, ''), '^@+', '')
      )
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.fangeo_handle_is_valid(p_handle text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.fangeo_normalize_handle(p_handle) IS NOT NULL
    AND char_length(public.fangeo_normalize_handle(p_handle)) BETWEEN 3 AND 20
    AND public.fangeo_normalize_handle(p_handle) ~ '^[a-z0-9_.]+$'
    AND public.fangeo_normalize_handle(p_handle) !~ '(^\.|\.$|[_.]{2})';
$$;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS handle text;

UPDATE public.user_profiles
SET username = public.fangeo_normalize_handle(username)
WHERE username IS NOT NULL
  AND username IS DISTINCT FROM public.fangeo_normalize_handle(username);

UPDATE public.user_profiles
SET handle = public.fangeo_normalize_handle(coalesce(handle, username))
WHERE public.fangeo_normalize_handle(coalesce(handle, username)) IS NOT NULL
  AND handle IS DISTINCT FROM public.fangeo_normalize_handle(coalesce(handle, username));

DO $$
DECLARE
  duplicate_record record;
  duplicate_count int := 0;
BEGIN
  FOR duplicate_record IN
    SELECT
      public.fangeo_normalize_handle(coalesce(handle, username)) AS normalized_handle,
      count(*) AS row_count,
      array_agg(id ORDER BY created_at NULLS LAST, id) AS profile_ids
    FROM public.user_profiles
    WHERE public.fangeo_normalize_handle(coalesce(handle, username)) IS NOT NULL
    GROUP BY public.fangeo_normalize_handle(coalesce(handle, username))
    HAVING count(*) > 1
  LOOP
    duplicate_count := duplicate_count + 1;
    RAISE NOTICE '[HandleValidationDebug] duplicateHandleDetected=% row_count=% profile_ids=%',
      duplicate_record.normalized_handle,
      duplicate_record.row_count,
      duplicate_record.profile_ids;
  END LOOP;

  IF duplicate_count = 0 THEN
    RAISE NOTICE '[HandleValidationDebug] duplicateHandleDetected=none';
  END IF;
END $$;

-- Display names are no longer unique. Keep display_name_normalized for search.
DROP INDEX IF EXISTS public.uq_user_profiles_display_name_normalized;

COMMENT ON COLUMN public.user_profiles.display_name_normalized IS
  'lower(trim(display_name)) when non-empty; used for search only. Display names are not unique.';

CREATE INDEX IF NOT EXISTS idx_user_profiles_display_name_normalized_lookup
  ON public.user_profiles (display_name_normalized)
  WHERE display_name_normalized IS NOT NULL;

ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_username_format_check;

ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_handle_format_check;

-- Format validation is enforced by the sync trigger only when a handle is
-- inserted or changed. That avoids breaking unrelated profile edits for legacy
-- rows that may already contain old handles outside the new 3-20 char rules.

CREATE INDEX IF NOT EXISTS idx_user_profiles_handle_lookup
  ON public.user_profiles (public.fangeo_normalize_handle(handle))
  WHERE handle IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_profiles_username_handle_lookup
  ON public.user_profiles (public.fangeo_normalize_handle(username))
  WHERE username IS NOT NULL;

DO $$
DECLARE
  duplicate_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles
    WHERE public.fangeo_normalize_handle(coalesce(handle, username)) IS NOT NULL
    GROUP BY public.fangeo_normalize_handle(coalesce(handle, username))
    HAVING count(*) > 1
  )
  INTO duplicate_exists;

  IF duplicate_exists THEN
    RAISE NOTICE '[HandleValidationDebug] duplicateHandleDetected=unique_index_skipped';
  ELSE
    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_profiles_handle_unique
      ON public.user_profiles (public.fangeo_normalize_handle(handle))
      WHERE handle IS NOT NULL;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.user_profiles_sync_handle_username()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  old_handle text;
  old_username text;
  next_handle text;
  username_changed boolean := false;
  handle_changed boolean := false;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    old_handle := public.fangeo_normalize_handle(OLD.handle);
    old_username := public.fangeo_normalize_handle(OLD.username);
    username_changed := public.fangeo_normalize_handle(NEW.username) IS DISTINCT FROM old_username;
    handle_changed := public.fangeo_normalize_handle(NEW.handle) IS DISTINCT FROM old_handle;
  END IF;

  IF TG_OP = 'UPDATE' AND username_changed THEN
    next_handle := public.fangeo_normalize_handle(NEW.username);
  ELSIF TG_OP = 'UPDATE' AND handle_changed THEN
    next_handle := public.fangeo_normalize_handle(NEW.handle);
  ELSE
    next_handle := coalesce(
      public.fangeo_normalize_handle(NEW.handle),
      public.fangeo_normalize_handle(NEW.username)
    );
  END IF;

  NEW.handle := next_handle;
  NEW.username := next_handle;

  IF next_handle IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT public.fangeo_handle_is_valid(next_handle) THEN
    RAISE EXCEPTION 'Invalid FanGeo handle: %', next_handle
      USING ERRCODE = '22023';
  END IF;

  IF TG_OP = 'INSERT'
    OR next_handle IS DISTINCT FROM coalesce(old_handle, old_username) THEN
    IF EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id IS DISTINCT FROM NEW.id
        AND public.fangeo_normalize_handle(coalesce(up.handle, up.username)) = next_handle
    ) THEN
      RAISE EXCEPTION 'FanGeo handle already taken: %', next_handle
        USING ERRCODE = '23505',
              CONSTRAINT = 'idx_user_profiles_handle_unique';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_sync_handle_username
  ON public.user_profiles;

CREATE TRIGGER trg_user_profiles_sync_handle_username
  BEFORE INSERT OR UPDATE OF handle, username ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.user_profiles_sync_handle_username();

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
    WHEN NOT public.fangeo_handle_is_valid(p_username) THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE public.fangeo_normalize_handle(coalesce(up.handle, up.username)) = public.fangeo_normalize_handle(p_username)
        AND up.id IS DISTINCT FROM COALESCE(p_exclude_user_id, auth.uid())
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.check_username_available_for_registration(p_username text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT public.fangeo_handle_is_valid(p_username) THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE public.fangeo_normalize_handle(coalesce(up.handle, up.username)) = public.fangeo_normalize_handle(p_username)
    )
  END;
$$;

-- Backward-compatible display-name RPC for older clients. Display names are non-unique.
CREATE OR REPLACE FUNCTION public.check_display_name_normalized_available(
  p_display_name text,
  p_exclude_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.check_display_name_normalized_available(p_display_name text)
RETURNS TABLE(available boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (auth.uid() IS NOT NULL)::boolean AS available;
$$;

REVOKE ALL ON FUNCTION public.check_username_available(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_username_available(text, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.check_username_available_for_registration(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_username_available_for_registration(text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.check_display_name_normalized_available(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_display_name_normalized_available(text, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.check_display_name_normalized_available(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_display_name_normalized_available(text) TO authenticated;

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
  n_handle := public.fangeo_normalize_handle(n);
  IF n = '' THEN
    RAISE EXCEPTION 'Enter a @handle, name, or email.';
  END IF;

  IF n_handle IS NOT NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND public.fangeo_normalize_handle(coalesce(up.handle, up.username)) = n_handle
    ORDER BY up.created_at ASC NULLS LAST, up.id
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND lower(trim(coalesce(up.email, ''))) = n
    ORDER BY up.created_at ASC NULLS LAST, up.id
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND up.display_name_normalized IS NOT NULL
      AND up.display_name_normalized = n
    ORDER BY up.created_at ASC NULLS LAST, up.id
    LIMIT 1;
  END IF;

  IF target IS NULL THEN
    SELECT up.id INTO target
    FROM public.user_profiles up
    WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND lower(trim(coalesce(up.display_name, ''))) = n
    ORDER BY up.created_at ASC NULLS LAST, up.id
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

COMMENT ON COLUMN public.user_profiles.handle IS
  'Public globally unique FanGeo @handle, stored lowercase without @. Synced with legacy username for app compatibility.';

COMMENT ON FUNCTION public.check_username_available(text, uuid) IS
  'True if normalized @handle is valid and globally unused by another profile.';

COMMENT ON FUNCTION public.check_username_available_for_registration(text) IS
  'True if normalized @handle is valid and globally unused; safe for pre-auth signup checks.';
