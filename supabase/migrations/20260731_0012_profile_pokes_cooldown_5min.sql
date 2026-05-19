-- Tune profile poke per-pair cooldown: 15 minutes -> 5 minutes (RPCs only; schema unchanged).

CREATE OR REPLACE FUNCTION public.poke_profile(p_target_user_id uuid)
RETURNS TABLE (
  poke_id uuid,
  created_at timestamptz,
  viewer_can_poke_now boolean,
  viewer_cooldown_ends_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  last_poke_at timestamptz;
  cooldown_ends timestamptz;
  inserted public.profile_pokes%ROWTYPE;
  cooldown_interval interval := interval '5 minutes';
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'Target user is required.';
  END IF;

  IF p_target_user_id = me THEN
    RAISE EXCEPTION 'You cannot poke yourself.';
  END IF;

  IF NOT public.profile_pokes_is_pokeable_fan(me) THEN
    RAISE EXCEPTION 'Your account cannot send pokes right now.';
  END IF;

  IF NOT public.profile_pokes_is_pokeable_fan(p_target_user_id) THEN
    RAISE EXCEPTION 'This profile cannot receive pokes.';
  END IF;

  IF public.profile_pokes_is_block_between(me, p_target_user_id) THEN
    RAISE EXCEPTION 'You cannot poke this user.';
  END IF;

  SELECT pp.created_at
  INTO last_poke_at
  FROM public.profile_pokes pp
  WHERE pp.poker_user_id = me
    AND pp.poked_user_id = p_target_user_id
  ORDER BY pp.created_at DESC
  LIMIT 1;

  IF last_poke_at IS NOT NULL THEN
    cooldown_ends := last_poke_at + cooldown_interval;
    IF cooldown_ends > now() THEN
      RETURN QUERY
      SELECT
        NULL::uuid,
        NULL::timestamptz,
        false,
        cooldown_ends;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.profile_pokes (poker_user_id, poked_user_id, source)
  VALUES (me, p_target_user_id, 'profile')
  RETURNING * INTO inserted;

  cooldown_ends := inserted.created_at + cooldown_interval;

  RETURN QUERY
  SELECT
    inserted.id,
    inserted.created_at,
    false,
    cooldown_ends;
END;
$$;

COMMENT ON FUNCTION public.poke_profile(uuid) IS
  'Authenticated fan pokes a profile. Enforces blocks, active non-business profiles, and 5-minute cooldown per pair.';

CREATE OR REPLACE FUNCTION public.get_profile_poke_summary(p_target_user_id uuid)
RETURNS TABLE (
  total_pokes bigint,
  unique_pokers bigint,
  viewer_last_poked_at timestamptz,
  viewer_can_poke_now boolean,
  viewer_cooldown_ends_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  last_poke_at timestamptz;
  cooldown_ends timestamptz;
  cooldown_interval interval := interval '5 minutes';
  can_poke boolean := false;
BEGIN
  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'Target user is required.';
  END IF;

  SELECT
    COUNT(*)::bigint,
    COUNT(DISTINCT pp.poker_user_id)::bigint
  INTO total_pokes, unique_pokers
  FROM public.profile_pokes pp
  WHERE pp.poked_user_id = p_target_user_id
    AND (
      me IS NULL
      OR NOT public.profile_pokes_is_block_between(me, pp.poker_user_id)
    );

  viewer_last_poked_at := NULL;
  viewer_cooldown_ends_at := NULL;

  IF me IS NOT NULL AND me <> p_target_user_id THEN
    SELECT pp.created_at
    INTO last_poke_at
    FROM public.profile_pokes pp
    WHERE pp.poker_user_id = me
      AND pp.poked_user_id = p_target_user_id
    ORDER BY pp.created_at DESC
    LIMIT 1;

    viewer_last_poked_at := last_poke_at;

    IF last_poke_at IS NOT NULL THEN
      cooldown_ends := last_poke_at + cooldown_interval;
      IF cooldown_ends > now() THEN
        viewer_cooldown_ends_at := cooldown_ends;
      END IF;
    END IF;

    can_poke :=
      public.profile_pokes_is_pokeable_fan(me)
      AND public.profile_pokes_is_pokeable_fan(p_target_user_id)
      AND NOT public.profile_pokes_is_block_between(me, p_target_user_id)
      AND viewer_cooldown_ends_at IS NULL;
  END IF;

  viewer_can_poke_now := can_poke;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.get_profile_poke_summary(uuid) IS
  'Poke totals for a profile plus whether auth.uid() can poke now (5-minute cooldown).';
