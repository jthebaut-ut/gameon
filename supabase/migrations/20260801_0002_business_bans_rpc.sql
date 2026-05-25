CREATE OR REPLACE FUNCTION public.get_my_active_business_ban(
  p_business_id uuid DEFAULT NULL,
  p_owner_email text DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  business_id uuid,
  owner_email text,
  is_permanent boolean,
  banned_until timestamptz,
  reason text,
  admin_note text,
  created_at timestamptz,
  server_now timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_jwt_email text := lower(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''));
  v_param_email text := lower(nullif(btrim(coalesce(p_owner_email, '')), ''));
  v_safe_email text := NULL;
  v_business_id_allowed boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  IF v_param_email IS NOT NULL AND v_jwt_email IS NOT NULL AND v_param_email = v_jwt_email THEN
    v_safe_email := v_param_email;
  ELSE
    v_safe_email := v_jwt_email;
  END IF;

  IF p_business_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = p_business_id
        AND (
          b.owner_user_id = v_uid
          OR (v_safe_email IS NOT NULL AND lower(b.owner_email) = v_safe_email)
        )
    )
    INTO v_business_id_allowed;
  END IF;

  RETURN QUERY
  SELECT
    bb.id,
    bb.business_id,
    bb.owner_email,
    bb.is_permanent,
    bb.banned_until,
    bb.reason,
    bb.admin_note,
    bb.created_at,
    now() AS server_now
  FROM public.business_bans bb
  WHERE bb.lifted_at IS NULL
    AND (bb.is_permanent = true OR bb.banned_until > now())
    AND (
      bb.owner_user_id = v_uid
      OR (v_safe_email IS NOT NULL AND lower(bb.owner_email) = v_safe_email)
      OR (v_business_id_allowed AND bb.business_id = p_business_id)
    )
  ORDER BY bb.created_at DESC
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_active_business_ban(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_active_business_ban(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.get_my_active_business_ban(uuid, text) IS
  'Returns the current authenticated user/business active business ban, bypassing business_bans RLS only after ownership checks.';
