-- Friend lookup: only regular fan `user_profiles` rows (exclude business-only identities).
-- Fixes legacy duplicate email (same email on a fan row and a business-marked row) resolving to the wrong user.
--
-- -----------------------------------------------------------------------------
-- ONE-TIME / MANUAL CLEANUP — legacy duplicate emails (fan + business profiles)
-- -----------------------------------------------------------------------------
-- Do NOT run destructive updates without ops review. Diagnostic query:
--
--   SELECT id, email, display_name, is_business_account, created_at
--   FROM public.user_profiles
--   WHERE COALESCE(lower(trim(admin_status)), '') = 'active'
--     AND lower(trim(email)) IN (
--       SELECT lower(trim(email))
--       FROM public.user_profiles
--       WHERE COALESCE(lower(trim(admin_status)), '') = 'active'
--         AND email IS NOT NULL AND trim(email) <> ''
--       GROUP BY lower(trim(email))
--       HAVING count(*) > 1
--     )
--   ORDER BY lower(trim(email)), COALESCE(is_business_account, false), created_at;
--
-- Remediation (example): assign a unique business-only email to the duplicate business row:
--   UPDATE public.user_profiles SET email = 'owner+alias@yourdomain.com' WHERE id = '<uuid>';
-- -----------------------------------------------------------------------------

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
    RAISE EXCEPTION 'Enter an email or display name.';
  END IF;

  -- Regular fan profiles only (business-only rows are not add-friend targets).
  SELECT up.id INTO target
  FROM public.user_profiles up
  WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND COALESCE(up.is_business_account, false) = false
    AND lower(trim(coalesce(up.email, ''))) = n
  ORDER BY up.created_at ASC NULLS LAST
  LIMIT 1;

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
    RAISE EXCEPTION 'No FanGeo account found with that email or display name.';
  END IF;

  PERFORM public.friendship_ensure_pending(target);
END;
$$;

REVOKE ALL ON FUNCTION public.send_friend_request_by_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request_by_lookup(text) TO authenticated;

COMMENT ON FUNCTION public.send_friend_request_by_lookup(text) IS
  'Friend lookup: active non-business user_profiles only (email, display_name_normalized, display_name); then friendship_ensure_pending.';
