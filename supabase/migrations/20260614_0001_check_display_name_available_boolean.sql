-- Replace table-returning preflight with a scalar boolean RPC + optional exclude id (PostgREST PGRST202 fix).

DROP FUNCTION IF EXISTS public.check_display_name_normalized_available(text);

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
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN p_exclude_user_id IS NOT NULL AND p_exclude_user_id IS DISTINCT FROM auth.uid() THEN false
    WHEN nullif(lower(trim(coalesce(p_display_name, ''))), '') IS NULL THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
        AND up.display_name_normalized IS NOT NULL
        AND up.display_name_normalized = nullif(lower(trim(coalesce(p_display_name, ''))), '')
        AND up.id IS DISTINCT FROM COALESCE(p_exclude_user_id, auth.uid())
    )
  END;
$$;

REVOKE ALL ON FUNCTION public.check_display_name_normalized_available(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_display_name_normalized_available(text, uuid) TO authenticated;

COMMENT ON FUNCTION public.check_display_name_normalized_available(text, uuid) IS
  'True if normalized display name is not taken by another active profile; false for empty input, anonymous caller, or wrong exclude id.';
