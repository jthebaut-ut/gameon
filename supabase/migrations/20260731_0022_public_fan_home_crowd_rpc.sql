-- Public-safe Home Crowd fetch for legacy client fallback when full identity RPC decode fails.

CREATE OR REPLACE FUNCTION public.get_public_fan_home_crowd(p_target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_target uuid := p_target_user_id;
  v_profile public.user_profiles%ROWTYPE;
BEGIN
  IF v_viewer IS NULL OR v_target IS NULL OR v_viewer = v_target THEN
    RETURN NULL;
  END IF;

  SELECT up.*
  INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = v_target
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND up.admin_disabled_at IS NULL
    AND COALESCE(up.is_business_account, false) = false
    AND COALESCE(up.discoverable_by_fans, true) = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = v_viewer AND b.blocked_user_id = v_target)
       OR (b.blocker_user_id = v_target AND b.blocked_user_id = v_viewer)
  ) THEN
    RETURN NULL;
  END IF;

  IF v_profile.home_crowd_venue_id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN public.home_crowd_venue_summary(
    v_profile.home_crowd_venue_id,
    v_profile.home_crowd_set_at,
    v_target
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_public_fan_home_crowd_pointer(p_target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_target uuid := p_target_user_id;
  v_profile public.user_profiles%ROWTYPE;
BEGIN
  IF v_viewer IS NULL OR v_target IS NULL OR v_viewer = v_target THEN
    RETURN NULL;
  END IF;

  SELECT up.*
  INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = v_target
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND up.admin_disabled_at IS NULL
    AND COALESCE(up.is_business_account, false) = false
    AND COALESCE(up.discoverable_by_fans, true) = true
  LIMIT 1;

  IF NOT FOUND OR v_profile.home_crowd_venue_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = v_viewer AND b.blocked_user_id = v_target)
       OR (b.blocker_user_id = v_target AND b.blocked_user_id = v_viewer)
  ) THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'venue_id', v_profile.home_crowd_venue_id,
    'home_crowd_set_at', v_profile.home_crowd_set_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_fan_home_crowd(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_fan_home_crowd(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_public_fan_home_crowd_pointer(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_fan_home_crowd_pointer(uuid) TO authenticated;
